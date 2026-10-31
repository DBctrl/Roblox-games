--!strict
-- T-025: remote spam against the shared token bucket (Contracts/RateLimit, T-004). Owned by qa.
-- Pure: uses RateLimit.newBucket/take with a fake clock, so it needs no Player (Studio Run mode is enough).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local TestKit = require(ReplicatedStorage:WaitForChild("QaTests"):WaitForChild("TestKit"))

local SPAMMED = { "TapBatch", "RequestBossFight", "BuyTool" }

return function(t: TestKit.Suite)
	local Contracts = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Contracts")
	local RateLimit = require(Contracts:WaitForChild("RateLimit")) :: any
	local Remotes = require(Contracts:WaitForChild("Remotes")) :: any

	t.test("every C->S remote has a finite rate > 0 and burst >= 1", function()
		for name, def in Remotes.Definitions do
			if def.direction == "C2S" then
				t.ok(type(def.rate) == "number" and def.rate > 0 and def.rate < math.huge, `{name} rate`)
				t.ok(type(def.burst) == "number" and def.burst >= 1 and def.burst < math.huge, `{name} burst`)
			end
		end
	end)

	for _, name in SPAMMED do
		t.test(`{name}: 1,000 calls in the same instant pass at most burst`, function()
			local def = Remotes.Definitions[name]
			local bucket = RateLimit.newBucket(def.burst, 100)
			local passed = 0
			for _ = 1, 1000 do
				if RateLimit.take(bucket, def.rate, def.burst, 100) then
					passed += 1
				end
			end
			t.eq(passed, math.floor(def.burst), `{name} passed`)
		end)

		t.test(`{name}: 60 s of spam at 1 kHz passes at most burst + rate x 60`, function()
			local def = Remotes.Definitions[name]
			local now = 0
			local bucket = RateLimit.newBucket(def.burst, now)
			local passed = 0
			for _ = 1, 60000 do
				now += 0.001
				if RateLimit.take(bucket, def.rate, def.burst, now) then
					passed += 1
				end
			end
			t.ok(passed <= def.burst + def.rate * 60 + 1, `{name} passed {passed}`)
		end)
	end

	t.test("a clock that goes backwards refills nothing", function()
		local bucket = RateLimit.newBucket(2, 50)
		t.ok(RateLimit.take(bucket, 1, 2, 50), "1st")
		t.ok(RateLimit.take(bucket, 1, 2, 50), "2nd")
		t.ok(not RateLimit.take(bucket, 1, 2, 10), "backwards clock")
		t.ok(not RateLimit.take(bucket, 1, 2, 10.5), "still no tokens after going back")
	end)

	t.test("a long idle never banks more than burst", function()
		local bucket = RateLimit.newBucket(3, 0)
		local passed = 0
		for _ = 1, 100 do
			if RateLimit.take(bucket, 2, 3, 1e6) then
				passed += 1
			end
		end
		t.eq(passed, 3, "passed after 1e6 s idle")
	end)
end
