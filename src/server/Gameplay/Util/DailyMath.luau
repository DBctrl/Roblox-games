--!strict
-- Pure daily-calendar rules (GDD 10, architecture 2 #14) for RewardService. Owned by gameplay-programmer.
-- Time is passed in (server os.time(), UTC), so qa can test day edges, missed days and clock jumps.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local EconomyConfig = require(ReplicatedStorage.Shared.Gameplay.EconomyConfig)

local DailyMath = {}

local DAYS = #EconomyConfig.DAILY_REWARDS -- 7

local function isFinite(x: any): boolean
	return typeof(x) == "number" and x == x and x ~= math.huge and x ~= -math.huge
end

-- UTC days since the Unix epoch.
function DailyMath.utcDay(unix: number): number
	return math.floor(unix / EconomyConfig.DAY_SEC)
end

-- Unix time when UTC day `day` starts.
function DailyMath.dayStart(day: number): number
	return day * EconomyConfig.DAY_SEC
end

-- What a claim on `today` gives. Returns (claimable, newStreak 1..7). Claimable only if `today` is after the last
-- claim day (one claim per UTC day; a clock that went back never allows a second claim). The streak continues
-- only when the last claim was exactly yesterday; otherwise, and after Day 7, it restarts at Day 1.
function DailyMath.claim(lastClaimDay: number, streak: number, today: number): (boolean, number)
	local last = if isFinite(lastClaimDay) then math.floor(lastClaimDay) else 0
	if today <= last then
		return false, 0
	end
	local s = if isFinite(streak) then math.clamp(math.floor(streak), 0, DAYS) else 0
	if last == today - 1 and s >= 1 and s < DAYS then
		return true, s + 1
	end
	return true, 1
end

-- Streak the calendar shows now: 0 once a day was missed (the next claim is Day 1 again).
function DailyMath.shownStreak(lastClaimDay: number, streak: number, today: number): number
	local last = if isFinite(lastClaimDay) then math.floor(lastClaimDay) else 0
	if last < today - 1 or not isFinite(streak) then
		return 0
	end
	return math.clamp(math.floor(streak), 0, DAYS)
end

return DailyMath
