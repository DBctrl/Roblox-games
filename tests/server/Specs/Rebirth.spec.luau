--!strict
-- T-046: rebirth resets exactly the right fields (architecture 3a "Reset on rebirth", GDD rev 2 4.5). Owned by qa.
-- Written against docs/architecture.md v1.2 1b (RebirthService.tryRebirth/getCost, ShopService.refreshAttributes)
-- and 3a, not against code.
--   * The field-classification test is pure (Run mode, F8): every ProfileSchema field must be listed below as
--     reset or kept, so a new schema field forces a rebirth decision.
--   * The live tests need a real Player (Play, F5) with a throwaway account or Studio's mock DataStore. They set
--     up a known profile, rebirth, check every field, then restore the snapshot. They SKIP in Run mode or while
--     RebirthService (T-030/T-031) is not merged.
--
-- GDD 4.5: Resets MP, coins, tools. Keeps pods, pets, rank and look, paid items, codes.
-- Architecture 3a: reset = coins (to 0), mp (to 0), toolIndex (to 1). Everything else is kept; rebirths += 1.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local TestKit = require(ReplicatedStorage:WaitForChild("QaTests"):WaitForChild("TestKit"))

local PLAYER_WAIT_SEC = 20
local ATTR_FLUSH_SEC = 0.6 -- DataService flushes attributes at <= 5 Hz (architecture 3b)

local RESET: { [string]: any } = { coins = 0, mp = 0, toolIndex = 1 }
-- Kept exactly (deep-equal before/after).
local KEEP = {
	"schemaVersion",
	"lifetimeMp",
	"podsMask",
	"world2Unlocked", -- never reset; only set true at Rebirth 3 (ZoneService)
	"firstWin",
	"rank",
	"quest",
	"pets",
	"pity", -- GDD 5: pity survives rejoin and rebirth
	"entitlements",
	"daily",
	"codes",
	"duel",
	"settings",
	"receipts",
}
-- Kept, but other services may write them during the test (boost ticking, funnel step, play time).
local VOLATILE = { "boosts", "stats", "milestones" }
local COUNTER = "rebirths"

local function waitForLoadedPlayer(): Player?
	local deadline = os.clock() + PLAYER_WAIT_SEC
	while os.clock() < deadline do
		for _, p in Players:GetPlayers() do
			if p:GetAttribute("DataLoaded") == true then
				return p
			end
		end
		task.wait(0.25)
	end
	return nil
end

return function(t: TestKit.Suite)
	local Server = ServerScriptService:FindFirstChild("Server")
	local ProfileSchema = TestKit.tryRequire(Server, { "Data", "Util", "ProfileSchema" }) :: any

	if ProfileSchema then
		t.test("every profile field is classified as reset, kept or the rebirth counter", function()
			local known: { [string]: boolean } = { [COUNTER] = true }
			for k in RESET do
				known[k] = true
			end
			for _, k in KEEP do
				known[k] = true
			end
			for _, k in VOLATILE do
				known[k] = true
			end
			local template = ProfileSchema.template()
			for k in template do
				t.ok(
					known[k],
					`profile field "{k}" has no rebirth rule in this spec (update architecture 3a + spec)`
				)
			end
			for k in known do
				t.ok(template[k] ~= nil, `spec field "{k}" is not in ProfileSchema.template()`)
			end
			for k, v in RESET do
				t.eq(template[k], v, `reset value of {k} equals its default`)
			end
		end)
	else
		t.skip("rebirth field classification", "Server.Data.Util.ProfileSchema not found")
	end

	local Shared = ReplicatedStorage:FindFirstChild("Shared")
	local EconomyConfig = TestKit.tryRequire(Shared, { "Gameplay", "EconomyConfig" }) :: any
	local DataService = TestKit.tryRequire(Server, { "Data", "DataService" }) :: any
	local RebirthService = TestKit.tryRequire(Server, { "Gameplay", "RebirthService" }) :: any
	local MultiplierService = TestKit.tryRequire(Server, { "Gameplay", "MultiplierService" }) :: any
	local ShopService = TestKit.tryRequire(Server, { "Gameplay", "ShopService" }) :: any
	local IdleService = TestKit.tryRequire(Server, { "Gameplay", "IdleService" }) :: any

	if RebirthService == nil or DataService == nil or EconomyConfig == nil or ProfileSchema == nil then
		t.skip("live rebirth tests", "RebirthService (T-030/T-031), DataService or EconomyConfig not merged")
		return
	end

	t.test("getCost(player) follows 15,000 x 3^(n-1) (GDD 4.5)", function()
		t.eq(EconomyConfig.rebirthCost(1), 15000, "rebirthCost(1)")
		t.eq(EconomyConfig.rebirthCost(2), 45000, "rebirthCost(2)")
		t.eq(EconomyConfig.rebirthCost(10), 15000 * 3 ^ 9, "rebirthCost(10)")
	end)

	local player = waitForLoadedPlayer()
	if player == nil then
		t.skip("live rebirth tests", "no loaded Player (run with Play, F5)")
		return
	end
	local p = player :: Player
	local snapshot = ProfileSchema.deepCopy(DataService.getData(p))

	local function restore()
		DataService.update(p, function(data: any)
			for k in data do
				data[k] = nil
			end
			for k, v in snapshot :: any do
				data[k] = ProfileSchema.deepCopy(v)
			end
		end)
		if MultiplierService and MultiplierService.refresh then
			MultiplierService.refresh(p)
		end
		if ShopService and ShopService.refreshAttributes then
			ShopService.refreshAttributes(p)
		end
	end

	-- Known profile at `rebirths` with `coins`: every kept field set off its default, no equipped pets and no
	-- boosts or paid tier, so M = rebirthMult(rebirths) exactly.
	local function setUp(rebirths: number, coins: number)
		DataService.update(p, function(d: any)
			d.rebirths = rebirths
			d.coins = coins
			d.mp = 4321
			d.lifetimeMp = 987654
			d.toolIndex = 4
			d.podsMask = 0b101
			d.firstWin = true
			d.rank = 5
			d.pets = {
				inventory = { ["1"] = { id = "QaPet" }, ["2"] = { id = "QaPet" } },
				equipped = {},
				nextUid = 3,
			}
			d.pity = { StarEgg = 4 }
			d.entitlements.paidTier = 0
			d.entitlements.vip = false
			d.entitlements.cosmetics = { RookieShades = true }
			d.boosts = { hypeSec = 0, coinSec = 0, speedSec = 0 }
			d.codes = { QATEST = true }
			table.insert(d.receipts, "qa-receipt")
		end)
		if MultiplierService and MultiplierService.refresh then
			MultiplierService.refresh(p)
		end
		if ShopService and ShopService.refreshAttributes then
			ShopService.refreshAttributes(p)
		end
	end

	local ok, err = pcall(function()
		t.test(
			"rebirth with enough coins: resets coins/MP/tools, keeps everything else, rebirths += 1",
			function()
				setUp(0, EconomyConfig.rebirthCost(1) + 777)
				t.eq(RebirthService.getCost(p), EconomyConfig.rebirthCost(1), "getCost at R0")
				local before = ProfileSchema.deepCopy(DataService.getData(p))
				local done, reason = RebirthService.tryRebirth(p)
				t.ok(done == true, `tryRebirth succeeded ({tostring(reason)})`)
				local after = DataService.getData(p)
				for k, v in RESET do
					t.eq(after[k], v, `{k} after rebirth`)
				end
				t.eq(after.rebirths, 1, "rebirths after rebirth")
				for _, k in KEEP do
					t.deepEq(after[k], before[k], `{k} kept`)
				end
				t.deepEq(after.boosts, before.boosts, "boosts kept (all 0 in setup)")
				t.eq(after.stats.firstJoinUnix, before.stats.firstJoinUnix, "stats.firstJoinUnix kept")
				t.ok(after.stats.bossWins >= before.stats.bossWins, "stats.bossWins not reset")
				t.eq(RebirthService.getCost(p), EconomyConfig.rebirthCost(2), "getCost at R1")
			end
		)

		t.test(
			"attributes follow the reset (Rebirths, Coins, Mp, ToolIndex, RebirthCost, Multiplier)",
			function()
				task.wait(ATTR_FLUSH_SEC)
				t.eq(p:GetAttribute("Rebirths"), 1, "Rebirths attribute")
				t.eq(p:GetAttribute("Coins"), 0, "Coins attribute")
				t.eq(p:GetAttribute("Mp"), 0, "Mp attribute")
				t.eq(
					p:GetAttribute("ToolIndex"),
					1,
					"ToolIndex attribute (ShopService.refreshAttributes, CR-a)"
				)
				t.eq(p:GetAttribute("RebirthCost"), EconomyConfig.rebirthCost(2), "RebirthCost attribute")
				if MultiplierService then
					t.near(
						MultiplierService.getMpMultiplier(p),
						EconomyConfig.rebirthMult(1),
						"M after rebirth",
						1e-9
					)
				end
				if IdleService then
					t.eq(p:GetAttribute("AutoMogUnlocked"), true, "AutoMogUnlocked at Rebirth 1 (GDD 4.6)")
				end
			end
		)

		t.test("rebirth with 1 coin short is refused and changes nothing", function()
			setUp(1, EconomyConfig.rebirthCost(2) - 1)
			local before = ProfileSchema.deepCopy(DataService.getData(p))
			local done = RebirthService.tryRebirth(p)
			t.ok(done ~= true, "tryRebirth refused")
			local after = DataService.getData(p)
			for k in RESET do
				t.eq(after[k], before[k], `{k} unchanged`)
			end
			t.eq(after.rebirths, 1, "rebirths unchanged")
			t.deepEq(after.pets, before.pets, "pets unchanged")
		end)

		t.test("corrupt coin balance (NaN) cannot rebirth", function()
			setUp(0, 0 / 0)
			local done = RebirthService.tryRebirth(p)
			t.ok(done ~= true, "tryRebirth refused with NaN coins")
			t.eq(DataService.getData(p).rebirths, 0, "rebirths unchanged")
		end)

		t.test("two rebirths in a row with coins for one: only one goes through", function()
			setUp(0, EconomyConfig.rebirthCost(1))
			local a = RebirthService.tryRebirth(p)
			local b = RebirthService.tryRebirth(p)
			t.ok(a == true and b ~= true, "first succeeds, second refused")
			t.eq(DataService.getData(p).rebirths, 1, "rebirths")
		end)
	end)
	restore()
	if not ok then
		error(err)
	end
end
