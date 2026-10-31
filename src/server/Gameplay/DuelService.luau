--!strict
-- DuelService (architecture 1b #17 and 4c, layer L3). Owned by gameplay-programmer.
-- Opt-in 8 s tap-off duels ("Mog-Offs"). Everything is decided here, on the server: challenges, the state machine,
-- the tap clamp, the score, the winner, rewards, anti-grief and forfeits. The client sends only intents
-- (challenge X, accept/decline, rematch yes/no, block X) and tap COUNTS through TapBatch; it never sends a score.
--
-- Phases: Pending (10 s) -> Countdown (3 s) -> Active (8 s) -> Result (2.5 s) -> Rematch window (10 s) -> Ended.
-- Score = taps x (1 + 0.03 x min(own rank, opponent rank + 2)) (EconomyConfig.duelScore): pets, paid tier, VIP,
-- boosts and auto-tap are never read, so money cannot buy a duel edge beyond rank (at most +6%, GDD 6).
-- Rewards (T-050): winner +1 weekly win and 120 x own best-boss coins/s, only under 5 rewarded wins per hour and
-- 2 per opponent per 15 min; losers lose nothing; rematch is free. Leaving, dying or losing the character during
-- Countdown/Active is a forfeit with no reward to anyone. The ring is released exactly once, when the duel ends.
-- Ordering for physics (T-066): `InDuel` stays true through Result and the Rematch window, and DuelState Result
-- is sent before PlayEffect DuelKnockback (which names the loser by UserId).
-- Sole writer of the InDuel and DuelWinsWeek attributes and of profile.duel.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ActivityService = require(script.Parent.ActivityService)
local BossService = require(script.Parent.BossService)
local Deps = require(script.Parent.Util.Deps)
local DuelMath = require(script.Parent.Util.DuelMath)
local EconomyConfig = require(ReplicatedStorage.Shared.Gameplay.EconomyConfig)
local Guard = require(script.Parent.Util.Guard)
local RankService = require(script.Parent.RankService)
local RateLimit = require(ReplicatedStorage.Shared.Contracts.RateLimit)
local Remotes = require(ReplicatedStorage.Shared.Contracts.Remotes)
local TapService = require(script.Parent.TapService)
local Types = require(ReplicatedStorage.Shared.Contracts.Types)

local Attr = Types.PlayerAttr

type DuelStatePayload = Types.DuelStatePayload
type Phase = "Countdown" | "Active" | "Result" | "Rematch" | "Ended"

local USER_ID_MAX = 2 ^ 53 -- any real UserId is a positive integer below this
local LOCK_REASON = "Duel" -- our CharacterService lock; World holds its own "DuelRing" lock (T-059)
local W1: Types.WorldId = 1

type Side = {
	player: Player,
	rank: number, -- snapshot at duel start (rank changes mid-duel do not move the score)
	tap: DuelMath.TapState,
	rematch: boolean,
	conns: { RBXScriptConnection },
}

type Duel = {
	sides: { Side }, -- [1] = challenger (pad 1), [2] = target (pad 2)
	worldId: Types.WorldId,
	ring: number,
	phase: Phase,
	seq: number, -- bumps on every phase change; stale timers compare it and do nothing
	activeStart: number,
	activeEnd: number,
	startedAt: number,
	released: boolean,
}

type Pending = {
	challenger: Player,
	target: Player,
	at: number,
}

local DuelService = {}

local duels: { [Player]: Duel } = {}
local pendingOut: { [Player]: Pending } = {} -- challenger -> their one pending challenge
local lastChallengeAt: { [Player]: { [number]: number } } = {} -- challenger -> target UserId -> time
local declineStreak: { [Player]: { [number]: number } } = {} -- target -> challenger UserId -> declines in a row
local mutedUntil: { [Player]: { [number]: number } } = {} -- target -> challenger UserId -> time
local blocks: { [Player]: { [number]: boolean } } = {} -- player -> blocked UserIds (session only)
local blockCount: { [Player]: number } = {}

local duelStateRemote: RemoteEvent? = nil
local notifyRemote: RemoteEvent? = nil
local effectRemote: RemoteEvent? = nil

local function now(): number
	return workspace:GetServerTimeNow()
end

local function setAttr(player: Player, name: string, value: any)
	if player.Parent == Players and player:GetAttribute(name) ~= value then
		player:SetAttribute(name, value)
	end
end

local function send(player: Player, payload: DuelStatePayload)
	if duelStateRemote and player.Parent == Players then
		duelStateRemote:FireClient(player, payload)
	end
end

local function notify(player: Player, text: string)
	if notifyRemote and player.Parent == Players then
		local payload: Types.NotifyPayload = { kind = "Info", text = text }
		notifyRemote:FireClient(player, payload)
	end
end

local function effect(players: { Player }, id: Types.EffectId, payload: Types.EffectPayload)
	if effectRemote == nil then
		return
	end
	for _, p in players do
		if p.Parent == Players then
			effectRemote:FireClient(p, id, payload)
		end
	end
end

local function subMap(map: { [Player]: { [number]: any } }, player: Player): { [number]: any }
	local m = map[player]
	if m == nil then
		m = {}
		map[player] = m
	end
	return m
end

local function playerByUserId(userId: any): Player?
	if not Guard.isIntInRange(userId, 1, USER_ID_MAX) then
		return nil
	end
	local p = Players:GetPlayerByUserId(userId)
	return if p and p.Parent == Players then p else nil
end

local function isTutorialDone(player: Player): boolean
	local data = Deps.data().getData(player)
	return data ~= nil and data.quest.done == true
end

local function opponentOf(duel: Duel, player: Player): Side?
	if duel.sides[1].player == player then
		return duel.sides[2]
	elseif duel.sides[2].player == player then
		return duel.sides[1]
	end
	return nil
end

-- Challenge checks (architecture 2 #9). `forAccept` skips the sender-side checks that the pending row itself
-- already passed (one pending outgoing, cooldown). Returns ok, reason.
local function canDuel(challenger: Player, target: Player, forAccept: boolean): (boolean, string?)
	local dataApi = Deps.data()
	if challenger == target then
		return false, "Self"
	end
	if not dataApi.isLoaded(challenger) or not dataApi.isLoaded(target) then
		return false, "NotLoaded"
	end
	if not isTutorialDone(challenger) or not isTutorialDone(target) then
		return false, "Tutorial"
	end
	if not dataApi.getSetting(target, "DuelRequests") then
		return false, "TargetOff"
	end
	if blocks[target] and blocks[target][challenger.UserId] then
		return false, "Blocked"
	end
	local mute = mutedUntil[target] and mutedUntil[target][challenger.UserId]
	if mute and now() < mute then
		return false, "Muted"
	end
	for _, p in { challenger, target } do
		if duels[p] or ActivityService.get(p) ~= "Idle" then
			return false, "Busy"
		end
	end
	if not forAccept then
		if pendingOut[challenger] then
			return false, "PendingOut"
		end
		local last = lastChallengeAt[challenger] and lastChallengeAt[challenger][target.UserId]
		if last and now() - last < EconomyConfig.DUEL_CHALLENGE_COOLDOWN_SEC then
			return false, "Cooldown"
		end
	end
	return true, nil
end

local REFUSE_TEXT: { [string]: string } = {
	Tutorial = "Duels unlock after the tutorial quests",
	TargetOff = "That player has duel requests turned off",
	Blocked = "That player is not taking challenges from you",
	Muted = "That player is not taking challenges from you right now",
	Busy = "That player is busy right now",
	PendingOut = "You already have a challenge waiting",
	Cooldown = "Wait a moment before challenging them again",
	NoRing = "Both Mog Rings are busy. Try again soon!",
}

-- Pending challenges ---------------------------------------------------------------------------------------

local function clearPending(pending: Pending)
	if pendingOut[pending.challenger] == pending then
		pendingOut[pending.challenger] = nil
	end
end

-- A decline or a 10 s timeout. Three in a row from the same target mute the challenger for that target.
local function countDecline(pending: Pending)
	local streaks = subMap(declineStreak, pending.target)
	local n = (streaks[pending.challenger.UserId] or 0) + 1
	if n >= EconomyConfig.DUEL_DECLINE_MUTE_COUNT then
		streaks[pending.challenger.UserId] = nil
		subMap(mutedUntil, pending.target)[pending.challenger.UserId] = now() + EconomyConfig.DUEL_MUTE_SEC
	else
		streaks[pending.challenger.UserId] = n
	end
end

local function endPending(pending: Pending, reason: string, counts: boolean)
	if pendingOut[pending.challenger] ~= pending then
		return
	end
	clearPending(pending)
	if counts then
		countDecline(pending)
	end
	send(pending.challenger, { phase = "Ended", opponentUserId = pending.target.UserId, reason = reason })
	send(pending.target, { phase = "Ended", opponentUserId = pending.challenger.UserId, reason = reason })
end

-- Duel lifecycle -------------------------------------------------------------------------------------------

local startCountdown: (duel: Duel) -> ()

local function phaseFor(duel: Duel, phase: Phase): number
	duel.phase = phase
	duel.seq += 1
	return duel.seq
end

local function after(duel: Duel, seconds: number, fn: (duel: Duel) -> ())
	local seq = duel.seq
	task.delay(seconds, function()
		if duel.seq == seq and duel.phase ~= "Ended" then
			fn(duel)
		end
	end)
end

local function disconnectSide(side: Side)
	for _, conn in side.conns do
		conn:Disconnect()
	end
	table.clear(side.conns)
end

-- Ends the duel for good: sinks removed, locks and activity released, ring released exactly once.
local function finish(duel: Duel, reason: string?)
	if duel.phase == "Ended" then
		return
	end
	phaseFor(duel, "Ended")
	local zone = Deps.zone()
	local character = Deps.character()
	for _, side in duel.sides do
		local p = side.player
		disconnectSide(side)
		TapService.setTapSink(p, nil)
		if duels[p] == duel then
			duels[p] = nil
		end
		local lock = character and character.setMovementLocked
		if lock and p.Parent == Players then
			lock(p, LOCK_REASON, false)
		end
		ActivityService.finish(p, "Duel")
		setAttr(p, Attr.InDuel, false)
		local opp = opponentOf(duel, p)
		send(p, { phase = "Ended", opponentUserId = opp and opp.player.UserId, reason = reason })
	end
	if not duel.released then
		duel.released = true
		local release = zone and zone.releaseRing
		if release then
			release(duel.worldId, duel.ring)
		end
	end
end

local function startRematchWindow(duel: Duel)
	phaseFor(duel, "Rematch")
	local t = now()
	for _, side in duel.sides do
		side.rematch = false
		local opp = opponentOf(duel, side.player) :: Side
		send(side.player, {
			phase = "Rematch",
			opponentUserId = opp.player.UserId,
			startsAt = t,
			endsAt = t + EconomyConfig.DUEL_REMATCH_SEC,
		})
	end
	after(duel, EconomyConfig.DUEL_REMATCH_SEC, function(d)
		finish(d, "Timeout")
	end)
end

-- Week rollover, reward caps and the coin payout for a winner. Returns the coins actually added (0 when capped).
local function payWinner(winner: Player, loser: Player): number
	local dataApi = Deps.data()
	local nowUnix = os.time()
	local week = DuelMath.weekId(nowUnix)
	local rewarded = false
	local weekWins = 0
	dataApi.update(winner, function(d)
		if d.duel.weekId ~= week then
			d.duel.weekId = week
			d.duel.weekWins = 0
		end
		local log = DuelMath.pruneRewardLog(d.duel.rewardLog, nowUnix)
		d.stats.duelWins += 1
		if DuelMath.rewardAllowed(log, nowUnix, loser.UserId) then
			rewarded = true
			d.duel.weekWins += 1
			table.insert(log, { t = nowUnix, opp = loser.UserId })
		end
		d.duel.rewardLog = log
		weekWins = d.duel.weekWins
	end)
	setAttr(winner, Attr.DuelWinsWeek, weekWins)
	if not rewarded then
		return 0
	end
	local coins = DuelMath.rewardCoins(BossService.bestCoinsPerSec(winner))
	if coins <= 0 then
		return 0
	end
	if dataApi.addCoins(winner, coins, "DuelReward") <= 0 then
		return 0
	end
	Deps.economy(winner, "Source", coins, "DuelReward")
	return coins
end

local function showResult(duel: Duel)
	local seq = phaseFor(duel, "Result")
	local a, b = duel.sides[1], duel.sides[2]
	local scoreA = EconomyConfig.duelScore(a.tap.taps, a.rank, b.rank)
	local scoreB = EconomyConfig.duelScore(b.tap.taps, b.rank, a.rank)
	local outcome = DuelMath.decide(scoreA, scoreB)
	local winner: Side? = if outcome == "A" then a elseif outcome == "B" then b else nil
	local loser: Side? = if outcome == "A" then b elseif outcome == "B" then a else nil

	local dataApi = Deps.data()
	for _, side in duel.sides do
		TapService.setTapSink(side.player, nil) -- taps go nowhere until a rematch; InDuel stays true
		dataApi.update(side.player, function(d)
			d.stats.duelsPlayed += 1
		end)
		Deps.custom(side.player, "DuelPlayed", now() - duel.startedAt)
	end
	local coins = 0
	if winner and loser then
		coins = payWinner(winner.player, loser.player)
		Deps.custom(winner.player, "DuelWon", now() - duel.startedAt)
	else
		for _, side in duel.sides do
			Deps.custom(side.player, "DuelDraw", now() - duel.startedAt)
		end
	end
	if duel.seq ~= seq then
		return -- a forfeit landed while paying (cannot yield today; kept as a guard)
	end

	-- 1) DuelState Result first (physics T-066 drops a knockback that arrives before it).
	local t = now()
	for _, side in duel.sides do
		local opp = opponentOf(duel, side.player) :: Side
		local mine = if side == a then scoreA else scoreB
		local theirs = if side == a then scoreB else scoreA
		local result: Types.DuelResult = if winner == nil
			then "Draw"
			elseif winner == side then "Win"
			else "Lose"
		send(side.player, {
			phase = "Result",
			opponentUserId = opp.player.UserId,
			startsAt = t,
			endsAt = t + EconomyConfig.DUEL_RESULT_SEC,
			myScore = mine,
			theirScore = theirs,
			result = result,
			rewardCoins = if winner == side then coins else 0,
		})
	end

	-- 2) Then the effect: knockback for the loser (only inside the ring), bounce for both on a draw.
	local both = { a.player, b.player }
	local zone = Deps.zone()
	if loser then
		local inRing = zone and zone.isInRing
		local knock = zone and zone.getRingKnockback
		local ok = inRing == nil or inRing(loser.player, duel.worldId, duel.ring)
		if ok and knock then
			effect(both, "DuelKnockback", {
				userId = loser.player.UserId,
				direction = knock(duel.worldId, duel.ring),
			})
		end
	else
		for _, side in duel.sides do
			effect(both, "DuelBounce", { userId = side.player.UserId })
		end
	end

	after(duel, EconomyConfig.DUEL_RESULT_SEC, startRematchWindow)
end

local function startActive(duel: Duel)
	phaseFor(duel, "Active")
	local t = now()
	duel.activeStart = t
	duel.activeEnd = t + EconomyConfig.DUEL_ACTIVE_SEC
	for _, side in duel.sides do
		side.tap = DuelMath.newTapState(t)
		local opp = opponentOf(duel, side.player) :: Side
		send(side.player, {
			phase = "Active",
			opponentUserId = opp.player.UserId,
			startsAt = duel.activeStart,
			endsAt = duel.activeEnd,
		})
	end
	-- Result waits out the grace window so the last in-flight batch still counts.
	after(duel, EconomyConfig.DUEL_ACTIVE_SEC + EconomyConfig.DUEL_GRACE_SEC, showResult)
end

-- Forfeit: no reward to anyone. Before Result it ends the duel; later it only closes the rematch window.
local function forfeit(duel: Duel, quitter: Player)
	if duel.phase == "Ended" then
		return
	end
	if duel.phase == "Countdown" or duel.phase == "Active" then
		for _, side in duel.sides do
			Deps.custom(side.player, "DuelForfeit", now() - duel.startedAt)
			if side.player ~= quitter then
				local payload: DuelStatePayload = {
					phase = "Result",
					opponentUserId = quitter.UserId,
					result = "Forfeit",
					rewardCoins = 0,
				}
				send(side.player, payload)
			end
		end
	end
	finish(duel, "Left")
end

local function watchCharacter(duel: Duel, side: Side)
	disconnectSide(side)
	local p = side.player
	local function onGone()
		if duels[p] == duel and (duel.phase == "Countdown" or duel.phase == "Active") then
			forfeit(duel, p)
		end
	end
	table.insert(side.conns, p.CharacterRemoving:Connect(onGone))
	local character = p.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		table.insert(side.conns, humanoid.Died:Connect(onGone))
	end
end

startCountdown = function(duel: Duel)
	phaseFor(duel, "Countdown")
	local zone = Deps.zone()
	local teleport = zone and zone.teleportToRing
	local t = now()
	for i, side in duel.sides do
		local p = side.player
		side.rematch = false
		side.rank = RankService.getRank(p)
		side.tap = DuelMath.newTapState(math.huge) -- no tap counts before Active
		if teleport then
			teleport(p, duel.worldId, duel.ring, i)
		end
		watchCharacter(duel, side)
		TapService.setTapSink(p, function(count: number)
			if duels[p] == duel and duel.phase == "Active" then
				DuelMath.acceptTaps(side.tap, count, now(), duel.activeStart, duel.activeEnd)
			end
		end)
		local opp = opponentOf(duel, p) :: Side
		send(p, {
			phase = "Countdown",
			opponentUserId = opp.player.UserId,
			startsAt = t,
			endsAt = t + EconomyConfig.DUEL_COUNTDOWN_SEC,
		})
	end
	after(duel, EconomyConfig.DUEL_COUNTDOWN_SEC, startActive)
end

-- Picks the ring world (challenger's world if the target has it unlocked, else World 1) and reserves a ring.
local function reserve(challenger: Player, target: Player): (Types.WorldId?, number?)
	local zone = Deps.zone()
	local reserveRing = zone and zone.reserveRing
	if zone == nil or reserveRing == nil or zone.releaseRing == nil then
		return nil, nil -- fail closed until ZoneService rings land (T-059)
	end
	local world = zone.getWorld(challenger)
	local targetData = Deps.data().getData(target)
	if world ~= W1 and not (targetData and targetData.world2Unlocked) then
		world = W1
	end
	local ring = reserveRing(world)
	if ring == nil and world ~= W1 then
		world = W1 -- lean v1 (D-034): rings exist only in Glow Town
		ring = reserveRing(world)
	end
	if ring == nil then
		return nil, nil
	end
	return world, ring
end

local function startDuel(challenger: Player, target: Player): (boolean, string?)
	local world, ring = reserve(challenger, target)
	if world == nil or ring == nil then
		return false, "NoRing"
	end
	local zone = Deps.zone()
	if not ActivityService.tryBegin(challenger, "Duel") then
		if zone and zone.releaseRing then
			zone.releaseRing(world, ring)
		end
		return false, "Busy"
	end
	if not ActivityService.tryBegin(target, "Duel") then
		ActivityService.finish(challenger, "Duel") -- roll back: both or neither
		if zone and zone.releaseRing then
			zone.releaseRing(world, ring)
		end
		return false, "Busy"
	end
	local function side(p: Player): Side
		return { player = p, rank = 1, tap = DuelMath.newTapState(math.huge), rematch = false, conns = {} }
	end
	local duel: Duel = {
		sides = { side(challenger), side(target) },
		worldId = world,
		ring = ring,
		phase = "Countdown",
		seq = 0,
		activeStart = math.huge,
		activeEnd = -math.huge,
		startedAt = now(),
		released = false,
	}
	local character = Deps.character()
	local lock = character and character.setMovementLocked
	for _, s in duel.sides do
		duels[s.player] = duel
		setAttr(s.player, Attr.InDuel, true)
		if lock then
			lock(s.player, LOCK_REASON, true)
		end
	end
	startCountdown(duel)
	return true, nil
end

-- Public API -----------------------------------------------------------------------------------------------

function DuelService.isInDuel(player: Player): boolean
	return duels[player] ~= nil
end

-- DuelChallenge: sender challenges `targetUserId`. All checks are server-side.
function DuelService.challenge(challenger: Player, targetUserId: number): (boolean, string?)
	local target = playerByUserId(targetUserId)
	if target == nil then
		return false, "BadArgs"
	end
	local ok, reason = canDuel(challenger, target, false)
	if not ok then
		return false, reason
	end
	local pending: Pending = { challenger = challenger, target = target, at = now() }
	pendingOut[challenger] = pending
	subMap(lastChallengeAt, challenger)[target.UserId] = pending.at
	local endsAt = pending.at + EconomyConfig.DUEL_PENDING_SEC
	send(
		challenger,
		{ phase = "Waiting", opponentUserId = target.UserId, startsAt = pending.at, endsAt = endsAt }
	)
	send(
		target,
		{ phase = "Invited", opponentUserId = challenger.UserId, startsAt = pending.at, endsAt = endsAt }
	)
	task.delay(EconomyConfig.DUEL_PENDING_SEC, endPending, pending, "Timeout", true) -- auto-decline
	return true, nil
end

-- DuelRespond: `target` answers a pending challenge from `challengerUserId`.
function DuelService.respond(target: Player, challengerUserId: number, accept: boolean): (boolean, string?)
	if typeof(accept) ~= "boolean" then
		return false, "BadArgs"
	end
	local challenger = playerByUserId(challengerUserId)
	local pending = challenger and pendingOut[challenger]
	if challenger == nil or pending == nil or pending.target ~= target then
		return false, "NoPending"
	end
	if now() - pending.at >= EconomyConfig.DUEL_PENDING_SEC then
		endPending(pending, "Timeout", true)
		return false, "NoPending"
	end
	if not accept then
		endPending(pending, "Declined", true)
		return true, nil
	end
	clearPending(pending)
	subMap(declineStreak, target)[challenger.UserId] = nil
	local ok, reason = canDuel(challenger, target, true)
	if ok then
		ok, reason = startDuel(challenger, target)
	end
	if not ok then
		send(challenger, { phase = "Ended", opponentUserId = target.UserId, reason = "Cancelled" })
		send(target, { phase = "Ended", opponentUserId = challenger.UserId, reason = "Cancelled" })
		return false, reason
	end
	return true, nil
end

-- DuelRematch: free; both must say yes inside the 10 s window. A "no" closes the window for both.
function DuelService.rematch(player: Player, accept: boolean): (boolean, string?)
	if typeof(accept) ~= "boolean" then
		return false, "BadArgs"
	end
	local duel = duels[player]
	if duel == nil or duel.phase ~= "Rematch" then
		return false, "NoWindow"
	end
	local me = if duel.sides[1].player == player then duel.sides[1] else duel.sides[2]
	local opp = opponentOf(duel, player) :: Side
	if not accept then
		finish(duel, "Declined")
		return true, nil
	end
	if opp.player.Parent ~= Players then
		finish(duel, "Left")
		return false, "Left"
	end
	me.rematch = true
	if opp.rematch then
		startCountdown(duel) -- same ring, still reserved; caps on rewards still apply
	end
	return true, nil
end

-- SetDuelBlock: session-only block list (max 50). Blocking also drops a pending challenge from that player.
function DuelService.setBlock(player: Player, targetUserId: number, blocked: boolean): (boolean, string?)
	if typeof(blocked) ~= "boolean" or not Guard.isIntInRange(targetUserId, 1, USER_ID_MAX) then
		return false, "BadArgs"
	end
	if targetUserId == player.UserId then
		return false, "Self"
	end
	local list = subMap(blocks, player)
	local n = blockCount[player] or 0
	if blocked and not list[targetUserId] then
		if n >= EconomyConfig.DUEL_BLOCK_MAX then
			return false, "Full"
		end
		list[targetUserId] = true
		blockCount[player] = n + 1
		local from = Players:GetPlayerByUserId(targetUserId)
		local pending = from and pendingOut[from]
		if pending and pending.target == player then
			endPending(pending, "Declined", false)
		end
	elseif not blocked and list[targetUserId] then
		list[targetUserId] = nil
		blockCount[player] = math.max(0, n - 1)
	end
	return true, nil
end

-- Lifecycle -------------------------------------------------------------------------------------------------

local function onLoaded(player: Player, data: Types.ProfileData?)
	local d = data or Deps.data().getData(player)
	if d == nil then
		return
	end
	local week = DuelMath.weekId(os.time())
	setAttr(player, Attr.DuelWinsWeek, if d.duel.weekId == week then d.duel.weekWins else 0)
	setAttr(player, Attr.InDuel, duels[player] ~= nil)
end

local function onRemoving(player: Player)
	local duel = duels[player]
	if duel then
		forfeit(duel, player)
	end
	local mine = pendingOut[player]
	if mine then
		endPending(mine, "Left", false)
	end
	for _, pending in pendingOut do
		if pending.target == player then
			endPending(pending, "Left", false)
		end
	end
	lastChallengeAt[player] = nil
	declineStreak[player] = nil
	mutedUntil[player] = nil
	blocks[player] = nil
	blockCount[player] = nil
end

function DuelService.Init() end

function DuelService.Start()
	duelStateRemote = Remotes.getEvent("DuelState")
	notifyRemote = Remotes.getEvent("Notify")
	effectRemote = Remotes.getEvent("PlayEffect")
	local dataApi = Deps.data()

	RateLimit.connect("DuelChallenge", function(player: Player, targetUserId: any)
		if not dataApi.isLoaded(player) or not Guard.isIntInRange(targetUserId, 1, USER_ID_MAX) then
			return
		end
		local ok, reason = DuelService.challenge(player, targetUserId)
		local text = if not ok and reason then REFUSE_TEXT[reason] else nil
		if text then
			notify(player, text)
		end
	end)

	RateLimit.connect("DuelRespond", function(player: Player, challengerUserId: any, accept: any)
		if not dataApi.isLoaded(player) or typeof(accept) ~= "boolean" then
			return
		end
		if not Guard.isIntInRange(challengerUserId, 1, USER_ID_MAX) then
			return
		end
		local ok, reason = DuelService.respond(player, challengerUserId, accept)
		local text = if not ok and reason then REFUSE_TEXT[reason] else nil
		if text then
			notify(player, text)
		end
	end)

	RateLimit.connect("DuelRematch", function(player: Player, accept: any)
		if dataApi.isLoaded(player) and typeof(accept) == "boolean" then
			DuelService.rematch(player, accept)
		end
	end)

	RateLimit.connect("SetDuelBlock", function(player: Player, targetUserId: any, blocked: any)
		if not dataApi.isLoaded(player) or typeof(blocked) ~= "boolean" then
			return
		end
		if Guard.isIntInRange(targetUserId, 1, USER_ID_MAX) then
			DuelService.setBlock(player, targetUserId, blocked)
		end
	end)

	dataApi.ProfileLoaded:Connect(onLoaded)
	dataApi.ProfileReleasing:Connect(onRemoving)
	Players.PlayerRemoving:Connect(onRemoving)
	for _, player in Players:GetPlayers() do
		if dataApi.isLoaded(player) then
			onLoaded(player, nil)
		end
	end
end

return DuelService
