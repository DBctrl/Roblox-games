--!strict
-- Pure duel rules (architecture 4c, GDD 6) used by DuelService. Owned by gameplay-programmer.
-- No Roblox services and no state of its own: time is passed in, so qa can drive floods, late batches, clock
-- jumps and reward-cap edges without players. Scoring reads taps and ranks only: pets, paid tier, VIP, boosts and
-- auto-tap never enter (they are not even parameters).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local EconomyConfig = require(ReplicatedStorage.Shared.Gameplay.EconomyConfig)

export type TapState = {
	taps: number, -- accepted taps so far (0..DUEL_TAP_TOTAL_MAX)
	clock: number, -- time up to which tap allowance has been used
}

export type RewardEntry = { t: number, opp: number }

local DuelMath = {}

local SECONDS_PER_WEEK = 7 * 24 * 60 * 60
local FIRST_SATURDAY_UNIX = 2 * 24 * 60 * 60 -- 1970-01-03 00:00 UTC (1970-01-01 was a Thursday)

local function isFinite(x: any): boolean
	return typeof(x) == "number" and x == x and x ~= math.huge and x ~= -math.huge
end

function DuelMath.newTapState(activeStart: number): TapState
	return { taps = 0, clock = activeStart }
end

-- Accepts part of a TapBatch `count` received at `now` for a duel whose tap-off runs [activeStart, activeEnd].
-- Rules: only batches received in [activeStart, activeEnd + DUEL_GRACE_SEC] count; at most DUEL_TAP_CAP_PER_SEC
-- per second of tap-off time (allowance never runs past activeEnd, and at most DUEL_TAP_BURST_SEC of unused
-- allowance is kept); the total never passes DUEL_TAP_TOTAL_MAX (80). Returns the whole taps accepted.
function DuelMath.acceptTaps(
	state: TapState,
	count: number,
	now: number,
	activeStart: number,
	activeEnd: number
): number
	if not isFinite(count) or count < 1 or not isFinite(now) then
		return 0
	end
	if now < activeStart or now > activeEnd + EconomyConfig.DUEL_GRACE_SEC then
		return 0
	end
	local rate = EconomyConfig.DUEL_TAP_CAP_PER_SEC
	local horizon = math.min(now, activeEnd)
	local from = math.max(state.clock, horizon - EconomyConfig.DUEL_TAP_BURST_SEC, activeStart)
	local allowance = math.floor(math.max(0, horizon - from) * rate + 1e-9)
	local room = EconomyConfig.DUEL_TAP_TOTAL_MAX - state.taps
	local accepted = math.max(0, math.min(math.floor(count), allowance, room))
	-- Advance the clock only by the time the accepted taps used, so fractional allowance is not lost.
	state.clock = from + accepted / rate
	state.taps += accepted
	return accepted
end

-- "A" / "B" / "Draw" from the two scores (equal scores = draw).
function DuelMath.decide(scoreA: number, scoreB: number): "A" | "B" | "Draw"
	if scoreA > scoreB then
		return "A"
	elseif scoreB > scoreA then
		return "B"
	end
	return "Draw"
end

-- Entries of `log` still inside the 1 h reward window (bad rows dropped). Never mutates `log`.
function DuelMath.pruneRewardLog(log: { RewardEntry }, nowUnix: number): { RewardEntry }
	local kept: { RewardEntry } = {}
	if typeof(log) ~= "table" then
		return kept
	end
	for _, row in log do
		if
			typeof(row) == "table"
			and isFinite(row.t)
			and isFinite(row.opp)
			and nowUnix - row.t < EconomyConfig.DUEL_REWARD_WINDOW_SEC
			and row.t <= nowUnix
		then
			table.insert(kept, { t = row.t, opp = row.opp })
		end
	end
	return kept
end

-- True if a win vs `oppUserId` at `nowUnix` may be rewarded: < 5 rewarded wins in the last hour and < 2 vs this
-- opponent in the last 15 min (GDD 6, stops win-trading with alts). `log` should be pruned first.
function DuelMath.rewardAllowed(log: { RewardEntry }, nowUnix: number, oppUserId: number): boolean
	local inHour, vsOpp = 0, 0
	for _, row in log do
		if nowUnix - row.t < EconomyConfig.DUEL_REWARD_WINDOW_SEC then
			inHour += 1
			if row.opp == oppUserId and nowUnix - row.t < EconomyConfig.DUEL_OPPONENT_WINDOW_SEC then
				vsOpp += 1
			end
		end
	end
	return inHour < EconomyConfig.DUEL_REWARDS_PER_HOUR and vsOpp < EconomyConfig.DUEL_REWARDS_PER_OPPONENT
end

-- Coins for a rewarded win: DUEL_REWARD_BOSS_SEC x the winner's best-boss coins/s, whole coins, never negative.
function DuelMath.rewardCoins(bestCoinsPerSec: number): number
	if not isFinite(bestCoinsPerSec) or bestCoinsPerSec <= 0 then
		return 0
	end
	return math.floor(EconomyConfig.DUEL_REWARD_BOSS_SEC * bestCoinsPerSec)
end

-- Weekly board id: whole weeks since Saturday 00:00 UTC (architecture 3d). Same id for the whole week.
function DuelMath.weekId(nowUnix: number): number
	return math.floor((nowUnix - FIRST_SATURDAY_UNIX) / SECONDS_PER_WEEK)
end

return DuelMath
