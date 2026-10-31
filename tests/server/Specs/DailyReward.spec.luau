--!strict
-- T-068: daily reward exploit tests. Claim twice, claim replay, clock skew (server hop to a server whose clock is
-- behind), missed day, junk time, and "VIP adds only 10 min Hype Snack". Owned by qa.
-- Written against docs/architecture.md v1.3 section 2 #14 and 3a (`daily = { streak, lastClaimDay }`, UTC days
-- since epoch) and GDD 10; not against code.
--
-- Two layers, each SKIPs on its own:
--   1. pure, Run mode (F8): `Gameplay/Util/DailyMath` (merged name, D-069 / QA-F13), through local adapters that
--      keep the tests' original shape:
--        claim(daily: { streak, lastClaimDay }, nowUnix) -> (ok, next: { streak, lastClaimDay }?)
--            = DailyMath.claim(daily.lastClaimDay, daily.streak, DailyMath.utcDay(nowUnix)) -> (ok, newStreak)
--        reward(day 1..7, bestCoinsPerSec, vip) -> { coins, hypeSec, coinSec, eggHatch }
--            = EconomyConfig.DAILY_REWARDS[day] (+ DAILY_VIP_HYPE_SEC when vip), the same rows RewardService.claim
--              pays from (RewardService has no pure reward function).
--      `nowUnix` is always the server's os.time() (RewardService.today()), so a non-number `now` is not reachable;
--      the claim adapter refuses a non-number or non-finite (NaN, inf) `now` instead of passing it on; every finite
--      junk time and every corrupt saved day still goes to DailyMath.
--   2. live, Play (F5): RewardService.claim(player) -> (boolean, string?) (the ClaimDailyReward path, D-069)

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local QaTests = ReplicatedStorage:WaitForChild("QaTests")
local Corpus = require(QaTests:WaitForChild("Fuzz"):WaitForChild("Corpus"))
local TestKit = require(QaTests:WaitForChild("TestKit"))

local DAY = 86400
local D = 20757 -- a UTC day number (2026-10-31)

local function at(day: number, sec: number): number
	return day * DAY + sec
end

return function(t: TestKit.Suite)
	local Server = ServerScriptService:FindFirstChild("Server")
	local Shared = ReplicatedStorage:FindFirstChild("Shared")
	local DailyMath = TestKit.tryRequire(Server, { "Gameplay", "Util", "DailyMath" }) :: any
	local EconomyConfig = TestKit.tryRequire(Shared, { "Gameplay", "EconomyConfig" }) :: any
	local RewardService = TestKit.tryRequire(Server, { "Gameplay", "RewardService" }) :: any
	local DataService = TestKit.tryRequire(Server, { "Data", "DataService" }) :: any

	local mathClaim = TestKit.firstFn(DailyMath, { "claim" })
	local utcDay = TestKit.firstFn(DailyMath, { "utcDay" })
	if mathClaim == nil or utcDay == nil then
		t.skip("daily calendar rules", "Gameplay/Util/DailyMath.claim / utcDay missing (D-069)")
	else
		-- Adapter: DailyMath.claim(lastClaimDay, streak, today) -> (ok, newStreak).
		local function claim(d: any, nowUnix: any): (boolean, any)
			if type(nowUnix) ~= "number" or nowUnix ~= nowUnix or math.abs(nowUnix) == math.huge then
				return false, nil -- not reachable: `now` is os.time()
			end
			local today = utcDay(nowUnix)
			local ok, streak = mathClaim(d.lastClaimDay, d.streak, today)
			if not ok then
				return false, nil
			end
			return true, { streak = streak, lastClaimDay = today }
		end
		local function daily(streak: number, last: number)
			return { streak = streak, lastClaimDay = last }
		end

		t.test("first claim starts the streak at day 1", function()
			local ok, n = claim(daily(0, 0), at(D, 3600))
			t.eq(ok, true, "first claim")
			t.eq(n.streak, 1, "streak")
			t.eq(n.lastClaimDay, D, "lastClaimDay")
		end)
		t.test("claim twice on the same UTC day: the second is refused", function()
			local ok1, n1 = claim(daily(0, 0), at(D, 10))
			t.eq(ok1, true, "first")
			for _, sec in { 11, 3600, DAY - 1 } do
				local ok2, n2 = claim(n1, at(D, sec))
				t.eq(ok2, false, `second claim at +{sec} s`)
				t.ok(
					n2 == nil or (n2.streak == n1.streak and n2.lastClaimDay == n1.lastClaimDay),
					"state changed"
				)
			end
		end)
		t.test("next UTC day continues the streak; a missed day restarts at day 1", function()
			local ok, n = claim(daily(3, D), at(D + 1, 1))
			t.eq(ok, true, "next day")
			t.eq(n.streak, 4, "streak continues")
			ok, n = claim(daily(3, D), at(D + 2, 1))
			t.eq(ok, true, "after a missed day")
			t.eq(n.streak, 1, "streak restarts")
		end)
		t.test(
			"clock skew: a server whose clock is behind the last claim refuses and keeps the streak",
			function()
				-- claimed on server A at D+1 00:00:05; hop to server B whose clock reads D 23:59:58
				local ok, n = claim(daily(5, D + 1), at(D, DAY - 2))
				t.eq(ok, false, "claim on the slow server")
				t.ok(
					n == nil or (n.streak == 5 and n.lastClaimDay == D + 1),
					"streak or lastClaimDay moved backwards"
				)
				-- a whole day behind
				ok = claim(daily(5, D + 1), at(D - 1, 100))
				t.eq(ok, false, "claim a day behind")
			end
		)
		t.test(
			"clock skew: a fast server can give at most one early claim, then the normal clock refuses",
			function()
				-- server A runs 10 s fast and reads D+1 00:00:05 while true time is D 23:59:55
				local ok1, n1 = claim(daily(2, D), at(D + 1, 5))
				t.eq(ok1, true, "early claim on the fast server")
				-- back on a correct server, still D+1 a minute later: no second claim
				local ok2 = claim(n1, at(D + 1, 65))
				t.eq(ok2, false, "second claim the same UTC day on a correct server")
			end
		)
		t.test("junk times and corrupt saved days never throw and never grant", function()
			for _, c in Corpus.BAD_NUMBERS do
				if type(c.value) == "number" and c.value >= 1e9 and c.value < math.huge then
					continue -- a real far-future time is a valid number
				end
				local ok, res = pcall(claim, daily(1, D), c.value)
				t.ok(ok, `claim(now = {c.label}) threw: {res}`)
				t.ok(res == false, `claim(now = {c.label}) granted`)
			end
			for _, last in { 1e12, 0 / 0, -1, math.huge } :: { number } do
				local ok, res = pcall(claim, daily(1, last), at(D, 100))
				t.ok(ok, `claim(lastClaimDay = {last}) threw: {res}`)
			end
		end)
	end

	local rows = EconomyConfig and EconomyConfig.DAILY_REWARDS
	if type(rows) ~= "table" or type(EconomyConfig.DAILY_VIP_HYPE_SEC) ~= "number" then
		t.skip("daily reward table", "EconomyConfig.DAILY_REWARDS / DAILY_VIP_HYPE_SEC missing")
	else
		-- Adapter: the payout RewardService.claim computes from one DAILY_REWARDS row.
		local function reward(day: number, bestCoinsPerSec: number, vip: boolean): any
			local row = rows[day]
			local hype = (row.hypeSec or 0) + (if vip then EconomyConfig.DAILY_VIP_HYPE_SEC else 0)
			return {
				coins = if row.coinSec then math.floor(row.coinSec * bestCoinsPerSec) else 0,
				hypeSec = hype,
				coinSec = row.coinSnackSec or 0,
				eggHatch = row.freeHatch == true,
			}
		end
		t.test(
			"VIP adds only 10 min Hype Snack; coin and egg rewards are the same (GDD 10, legal RC-1 c)",
			function()
				for day = 1, 7 do
					local free = reward(day, 100, false)
					local vip = reward(day, 100, true)
					t.eq(vip.coins or 0, free.coins or 0, `day {day} coins`)
					t.eq(vip.eggHatch or vip.egg, free.eggHatch or free.egg, `day {day} egg`)
					t.eq((vip.hypeSec or 0) - (free.hypeSec or 0), 600, `day {day} VIP extra Hype`)
					t.eq(vip.coinSec or 0, free.coinSec or 0, `day {day} Coin Snack`)
				end
			end
		)
		t.test("coin days pay N minutes of best-boss coins/s (GDD 10: D1 2, D3 5, D6 10, D7 15)", function()
			for day, minutes in { [1] = 2, [3] = 5, [6] = 10, [7] = 15 } do
				t.near(reward(day, 100, false).coins or 0, minutes * 60 * 100, `day {day} coins`)
			end
			for _, day in { 2, 4, 5 } do
				t.eq(reward(day, 100, false).coins or 0, 0, `day {day} has no coins`)
			end
		end)
	end

	if RewardService == nil or DataService == nil then
		t.skip("live daily claim", "RewardService (T-052) not merged")
		return
	end
	local claimDaily = TestKit.firstFn(RewardService, { "claim" })
	if claimDaily == nil then
		t.skip("live daily claim", "RewardService.claim seam missing (D-069)")
		return
	end
	local players = TestKit.loadedPlayers(1)
	if #players == 0 then
		t.skip("live daily claim", "no Player with DataLoaded (use Play, not Run)")
		return
	end
	local plr: Player = players[1]
	t.test("claim replay: two claims back to back, the second changes nothing", function()
		pcall(claimDaily :: any, plr) -- may be refused if this account already claimed today
		local d = DataService.getData(plr)
		local before = { coins = d.coins, streak = d.daily.streak, last = d.daily.lastClaimDay, inv = 0 }
		before.inv = TestKit.count(d.pets.inventory)
		for i = 1, 5 do
			local ok, res = pcall(claimDaily :: any, plr, at(D + 100, 0), true, 999) -- extra args must be ignored
			t.ok(ok, `replay {i} threw: {res}`)
			t.eq(res, false, `replay {i}`)
		end
		d = DataService.getData(plr)
		t.eq(d.coins, before.coins, "coins")
		t.eq(d.daily.streak, before.streak, "streak")
		t.eq(d.daily.lastClaimDay, before.last, "lastClaimDay")
		t.eq(TestKit.count(d.pets.inventory), before.inv, "pets")
	end)
end
