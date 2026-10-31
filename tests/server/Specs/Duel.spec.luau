--!strict
-- T-068: duel exploit tests. Tap flood, self-duel, challenge spam, win-trading and rematch reward caps, forfeit,
-- and "pets, paid tier, VIP and boosts never count". Owned by qa.
-- Written against docs/architecture.md v1.3 section 2 (#9-#12) and 4c, and GDD section 6; not against code.
--
-- Three layers, each SKIPs on its own:
--   1. pure, Run mode (F8): `EconomyConfig.duelScore` (named in 4c) and the duel constants
--   2. pure, Run mode: `Gameplay/Util/DuelRules` (QA-F13 asks for it)
--        rewardAllowed(rewardLog: { { t: number, opp: number } }, now: number, oppUserId: number): boolean
--        acceptTaps(count: any, now: number, lastAccepted: number, activeStart: number, activeEnd: number,
--                   total: number): number   -- taps accepted from one TapBatch
--   3. live, Play (F5): DuelService.challenge(player, targetUserId) / respond(player, challengerUserId, accept) /
--      rematch(player, accept) -> (boolean, string?) (QA-F13). Self-duel and bad ids need 1 player; spam and
--      cooldown need 2 (Test > Clients and Servers, 2 players, both past the tutorial).
-- Forfeit on leave and ring release need a player to leave mid-duel: `check_duel.py` checks them statically and
-- the build playtest script covers them by hand.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local QaTests = ReplicatedStorage:WaitForChild("QaTests")
local Corpus = require(QaTests:WaitForChild("Fuzz"):WaitForChild("Corpus"))
local TestKit = require(QaTests:WaitForChild("TestKit"))

local HOUR = 3600
local OPP_WINDOW = 15 * 60

return function(t: TestKit.Suite)
	local Server = ServerScriptService:FindFirstChild("Server")
	local Shared = ReplicatedStorage:FindFirstChild("Shared")
	local EconomyConfig = TestKit.tryRequire(Shared, { "Gameplay", "EconomyConfig" }) :: any
	local DuelRules = TestKit.tryRequire(Server, { "Gameplay", "Util", "DuelRules" }) :: any
	local DuelService = TestKit.tryRequire(Server, { "Gameplay", "DuelService" }) :: any

	-- 1. Score and constants ---------------------------------------------------------------------------------
	if EconomyConfig == nil then
		t.skip("duel constants and score", "EconomyConfig missing")
	else
		t.test("duel constants match GDD 6 / architecture 4c", function()
			t.eq(EconomyConfig.DUEL_TAP_CAP_PER_SEC, 10, "tap cap per second")
			t.eq(EconomyConfig.DUEL_ACTIVE_SEC, 8, "active seconds")
			t.eq(EconomyConfig.DUEL_PENDING_SEC, 10, "pending seconds")
			t.eq(EconomyConfig.DUEL_REMATCH_SEC, 10, "rematch window")
			t.eq(EconomyConfig.DUEL_GRACE_SEC, 0.5, "grace")
			t.eq(EconomyConfig.DUEL_REWARD_BOSS_SEC, 120, "reward = 2 min of best-boss coins/s")
			t.eq(EconomyConfig.DUEL_REWARDS_PER_HOUR, 5, "rewarded wins per hour")
			t.eq(EconomyConfig.DUEL_REWARDS_PER_OPPONENT, 2, "rewarded wins per opponent")
			t.eq(EconomyConfig.DUEL_OPPONENT_WINDOW_SEC, OPP_WINDOW, "opponent window")
			t.eq(EconomyConfig.DUEL_RANK_STEP, 0.03, "rank step")
			t.eq(EconomyConfig.DUEL_RANK_EDGE, 2, "rank edge")
		end)

		local duelScore = EconomyConfig.duelScore
		if type(duelScore) ~= "function" then
			t.skip("duelScore tests", "EconomyConfig.duelScore (architecture 4c) not written yet (QA-F12)")
		else
			t.test(
				"duelScore takes only taps and the two ranks (no pet, paid, VIP or boost input)",
				function()
					local arity, vararg = debug.info(duelScore, "a")
					t.eq(arity, 3, "duelScore parameter count")
					t.eq(vararg, false, "duelScore is not variadic")
				end
			)
			t.test("duelScore = taps x (1 + 0.03 x min(own, opp + 2))", function()
				t.near(duelScore(80, 1, 1), 80 * 1.03, "80 taps, rank 1 v 1")
				t.near(duelScore(80, 5, 5), 80 * 1.15, "rank 5 v 5")
				t.near(duelScore(80, 12, 1), 80 * 1.09, "rank 12 v 1 is capped at RankEff 3")
				t.near(duelScore(80, 3, 10), 80 * 1.09, "lower rank uses its own rank")
				t.near(duelScore(0, 12, 12), 0, "no taps, no score")
			end)
			t.test("rank edge never exceeds +6% for equal taps (GDD 6)", function()
				local worst = 0
				for own = 1, 12 do
					for opp = 1, 12 do
						worst = math.max(worst, duelScore(80, own, opp) / duelScore(80, opp, own))
					end
				end
				t.ok(worst <= 1.06 + 1e-9, `largest edge {worst}`)
			end)
			t.test("duelScore with junk taps or ranks never returns NaN or inf", function()
				for _, c in Corpus.BAD_NUMBERS do
					local ok, s = pcall(duelScore, c.value, 3, 3)
					if ok then
						t.ok(s == s and math.abs(s) ~= math.huge, `duelScore({c.label}, 3, 3) = {s}`)
					end
				end
			end)
		end
	end

	-- 2. Pure rules ------------------------------------------------------------------------------------------
	local rewardAllowed = TestKit.firstFn(DuelRules, { "rewardAllowed", "canReward" })
	if rewardAllowed == nil then
		t.skip("duel reward cap tests", "Gameplay/Util/DuelRules.rewardAllowed missing (QA-F13)")
	else
		local allowed: (any, number, number) -> boolean = rewardAllowed
		local now = 1_800_000_000
		local function log(entries: { { number } }): { { t: number, opp: number } }
			local out = {}
			for _, e in entries do
				table.insert(out, { t = now - e[1], opp = e[2] })
			end
			return out
		end
		t.test("rewarded wins: 5 per hour", function()
			t.eq(allowed({}, now, 7), true, "first win")
			t.eq(
				allowed(log({ { 60, 1 }, { 600, 2 }, { 1200, 3 }, { 2400, 4 } }), now, 7),
				true,
				"4 in the hour"
			)
			t.eq(
				allowed(log({ { 60, 1 }, { 600, 2 }, { 1200, 3 }, { 2400, 4 }, { 3000, 5 } }), now, 7),
				false,
				"5 in the hour"
			)
			t.eq(
				allowed(
					log({
						{ HOUR + 1, 1 },
						{ HOUR + 2, 2 },
						{ HOUR + 3, 3 },
						{ HOUR + 4, 4 },
						{ HOUR + 5, 5 },
					}),
					now,
					7
				),
				true,
				"5 older than an hour"
			)
		end)
		t.test("win-trading with an alt: 2 per opponent per 15 min", function()
			t.eq(allowed(log({ { 30, 9 } }), now, 9), true, "1 vs this opponent")
			t.eq(allowed(log({ { 30, 9 }, { 300, 9 } }), now, 9), false, "2 vs this opponent in 15 min")
			t.eq(
				allowed(log({ { 30, 9 }, { OPP_WINDOW + 1, 9 } }), now, 9),
				true,
				"second one is older than 15 min"
			)
			t.eq(allowed(log({ { 30, 9 }, { 300, 9 } }), now, 10), true, "a different opponent is fine")
		end)
		t.test("rematch loop: the third straight win over one opponent earns nothing", function()
			-- simulate A beating B in a rematch loop every 30 s for 10 minutes
			local rewardLog = {}
			local rewarded = 0
			for i = 0, 19 do
				local tNow = now + i * 30
				if allowed(rewardLog, tNow, 42) then
					rewarded += 1
					table.insert(rewardLog, { t = tNow, opp = 42 })
				end
			end
			t.eq(rewarded, 2, "rewarded wins in a 10 min rematch loop")
		end)
		t.test("alternating wins between two accounts are capped for both", function()
			local logs = { [1] = {}, [2] = {} }
			local rewarded = { [1] = 0, [2] = 0 }
			for i = 0, 39 do
				local winner = if i % 2 == 0 then 1 else 2
				local opp = 3 - winner
				local tNow = now + i * 20
				if allowed(logs[winner], tNow, opp) then
					rewarded[winner] += 1
					table.insert(logs[winner], { t = tNow, opp = opp })
				end
			end
			t.eq(rewarded[1], 2, "account 1 rewarded wins in 13 min")
			t.eq(rewarded[2], 2, "account 2 rewarded wins in 13 min")
		end)
		t.test("a log entry from the future (clock skew) still counts against the cap", function()
			t.eq(
				allowed(log({ { -120, 9 }, { -60, 9 } }), now, 9),
				false,
				"2 future entries vs this opponent"
			)
		end)
	end

	local acceptTaps = TestKit.firstFn(DuelRules, { "acceptTaps", "clampTaps" })
	if acceptTaps == nil then
		t.skip("duel tap-flood tests", "Gameplay/Util/DuelRules.acceptTaps missing (QA-F13)")
	else
		local accept: (any, number, number, number, number, number) -> number = acceptTaps
		local s, e = 100, 108
		t.test("tap flood: one huge batch is clamped to 10/s x elapsed", function()
			t.ok(accept(1e9, s + 0.5, s, s, e, 0) <= 5, "0.5 s after the start")
			t.ok(accept(30, s + 1, s + 0.5, s, e, 5) <= 5, "0.5 s after the last batch")
			t.ok(accept(30, s + 1, s + 1, s, e, 10) == 0, "same timestamp twice")
		end)
		t.test("tap flood: the total never passes 80", function()
			local total, last = 0, s
			for i = 1, 200 do
				local tNow = s + i * 0.05
				local got = accept(30, tNow, last, s, e, total)
				if got > 0 then
					last = tNow
				end
				total += got
			end
			t.ok(total <= 80, `total {total}`)
		end)
		t.test("taps outside the window (before start, after end + 0.5 s grace) count 0", function()
			t.eq(accept(5, s - 0.1, s - 1, s, e, 0), 0, "before Active")
			t.eq(accept(5, e + 0.6, e - 1, s, e, 10), 0, "after the grace")
			t.ok(accept(5, e + 0.4, e - 0.1, s, e, 10) <= 5, "inside the grace, clamped by elapsed")
		end)
		t.test("junk tap counts give 0 and never throw", function()
			local cases = table.clone(Corpus.NON_NUMBERS)
			for _, c in Corpus.BAD_NUMBERS do
				table.insert(cases, c)
			end
			for _, c in cases do
				local ok, got = pcall(accept, c.value, s + 2, s + 1, s, e, 0)
				t.ok(ok, `acceptTaps({c.label}) threw: {got}`)
				if ok then
					t.ok(got == got and got >= 0 and got <= 10, `acceptTaps({c.label}) = {got}`)
					t.ok(
						got == 0 or (type(c.value) == "number" and c.value >= 1),
						`acceptTaps({c.label}) = {got}`
					)
				end
			end
		end)
	end

	-- 3. Live ------------------------------------------------------------------------------------------------
	if DuelService == nil then
		t.skip("live duel tests", "DuelService (T-049/T-050) not merged")
		return
	end
	local challenge = TestKit.firstFn(DuelService, { "challenge", "tryChallenge" })
	local respond = TestKit.firstFn(DuelService, { "respond", "tryRespond" })
	if challenge == nil then
		t.skip("live duel tests", "DuelService.challenge seam missing (QA-F13)")
		return
	end
	local players = TestKit.loadedPlayers(1)
	if #players == 0 then
		t.skip("live duel tests", "no Player with DataLoaded (use Play, not Run)")
		return
	end
	local a: Player = players[1]
	local ch: (Player, any) -> (boolean, string?) = challenge

	t.test("self-duel is refused", function()
		local ok, res = pcall(ch, a, a.UserId)
		t.ok(ok, `challenge(self) threw: {res}`)
		t.eq(res, false, "challenge(self)")
		t.eq(DuelService.isInDuel(a), false, "isInDuel after a self challenge")
	end)
	t.test("bad target ids are refused without an error", function()
		local cases = table.clone(Corpus.NON_NUMBERS)
		for _, c in Corpus.BAD_NUMBERS do
			table.insert(cases, c)
		end
		table.insert(cases, { label = "absent user 1", value = 1 })
		table.insert(cases, { label = "self + 0.5", value = a.UserId + 0.5 })
		for _, c in cases do
			local ok, res = pcall(ch, a, c.value)
			t.ok(ok, `challenge({c.label}) threw: {res}`)
			t.eq(res, false, `challenge({c.label})`)
		end
		t.eq(DuelService.isInDuel(a), false, "isInDuel")
	end)
	if respond then
		t.test("responding to a challenge that does not exist does nothing", function()
			for _, v in { a.UserId, 1, 0 / 0, "x" } :: { any } do
				local ok, res = pcall(respond :: any, a, v, true)
				t.ok(ok, `respond({tostring(v)}) threw: {res}`)
				t.eq(res, false, `respond({tostring(v)})`)
			end
			t.eq(DuelService.isInDuel(a), false, "isInDuel")
		end)
	end

	local two = TestKit.loadedPlayers(2, 5)
	if #two < 2 then
		t.skip("challenge spam and cooldown", "needs 2 players (Test > Clients and Servers, 2 players)")
		return
	end
	local b: Player = if two[1] == a then two[2] else two[1]
	t.test("challenge spam: 1 pending outgoing, the rest refused; 15 s cooldown after a decline", function()
		local first = ch(a, b.UserId)
		if not first then
			error("first challenge refused: both players must be past the tutorial with duel requests On")
		end
		for i = 1, 20 do
			t.eq((ch(a, b.UserId)), false, `spam challenge {i}`)
		end
		if respond then
			t.eq((respond :: any)(b, a.UserId, false), true, "decline")
			t.eq((ch(a, b.UserId)), false, "re-challenge inside the 15 s cooldown")
		end
		t.eq(DuelService.isInDuel(a), false, "a not in a duel")
		t.eq(DuelService.isInDuel(b), false, "b not in a duel")
	end)
end
