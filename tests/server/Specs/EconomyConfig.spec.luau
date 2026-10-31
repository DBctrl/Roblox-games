--!strict
-- T-024: EconomyConfig.validate() and tables-match-GDD. Owned by qa.
-- Compares ReplicatedStorage.Shared.Gameplay.EconomyConfig (T-006, gameplay-programmer) with the GDD fixture
-- generated from docs/gdd.md. Pure: needs no Player, so it runs in Studio Run mode (F8).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local QaTests = ReplicatedStorage:WaitForChild("QaTests")
local GddTables = require(QaTests:WaitForChild("Fixtures"):WaitForChild("GddTables"))
local TestKit = require(QaTests:WaitForChild("TestKit"))

local field = TestKit.field

-- Entries of an array, or of a map sorted by `sortKey` (BOSSES may be keyed by boss id, see QA-F4).
local function entries(tbl: any, sortField: { string }): { any }
	local list = {}
	if type(tbl) ~= "table" then
		return list
	end
	if #tbl > 0 then
		for _, v in ipairs(tbl) do
			table.insert(list, v)
		end
		return list
	end
	for k, v in pairs(tbl) do
		if type(v) == "table" then
			if v.id == nil and v.bossId == nil then
				v = table.clone(v)
				v.id = k
			end
			table.insert(list, v)
		end
	end
	table.sort(list, function(a, b)
		return field(a, sortField, "sort") < field(b, sortField, "sort")
	end)
	return list
end

local POWER = { "power", "mpPerTap", "mp" }
local COST = { "cost", "price" }
local WORLD = { "world", "worldId" }
local RATE = { "rate", "mpPerSec", "baseRate" }
local NEED = { "need", "mpNeeded", "threshold", "mpNeed" }
local COINS = { "coins", "coinsPerWin", "reward" }
local LIFETIME = { "lifetimeMp", "lifetime", "threshold", "minLifetimeMp" }
local BOSS_ID = { "id", "bossId" }

return function(t: TestKit.Suite)
	local Shared = ReplicatedStorage:FindFirstChild("Shared")
	local EconomyConfig = TestKit.tryRequire(Shared, { "Gameplay", "EconomyConfig" })
	if EconomyConfig == nil then
		t.skip("all EconomyConfig checks", "Shared.Gameplay.EconomyConfig not found (T-006 not merged)")
		return
	end
	local E: any = EconomyConfig

	t.test("validate() runs without error", function()
		t.eq(type(E.validate), "function", "EconomyConfig.validate")
		E.validate()
	end)

	t.test("caps and constants (architecture 1c)", function()
		t.eq(E.TAP_CAP_PER_SEC, 12, "TAP_CAP_PER_SEC")
		t.eq(E.DUEL_TAP_CAP_PER_SEC, 10, "DUEL_TAP_CAP_PER_SEC")
		t.eq(E.M_CLAMP, 10000, "M_CLAMP")
		t.eq(E.PET_MULT_CAP, 25, "PET_MULT_CAP")
		t.eq(E.INVENTORY_CAP, 60, "INVENTORY_CAP")
		t.eq(E.INTERACT_RANGE, 20, "INTERACT_RANGE")
		if E.TAP_BATCH_MAX ~= nil then
			t.eq(E.TAP_BATCH_MAX, 30, "TAP_BATCH_MAX (architecture 2 #1)")
		end
	end)

	t.test("TOOLS match GDD 4.2", function()
		local list = entries(E.TOOLS, COST)
		t.eq(#list, #GddTables.TOOLS, "tool count")
		for i, g in GddTables.TOOLS do
			local e = list[i]
			t.eq(field(e, POWER, `tool {i}`), g.power, `tool {i} {g.name} MP/tap`)
			t.eq(field(e, COST, `tool {i}`), g.cost, `tool {i} {g.name} cost`)
			t.eq(field(e, WORLD, `tool {i}`), g.world, `tool {i} {g.name} world`)
		end
	end)

	t.test("PODS match GDD 4.3", function()
		local list = entries(E.PODS, COST)
		t.eq(#list, #GddTables.PODS, "pod count")
		for i, g in GddTables.PODS do
			t.eq(field(list[i], RATE, `pod {i}`), g.rate, `pod {i} {g.name} MP/s`)
			t.eq(field(list[i], COST, `pod {i}`), g.cost, `pod {i} {g.name} cost`)
		end
	end)

	t.test("BOSSES match GDD 4.4; ids are unique strings <= 32 chars", function()
		local list = entries(E.BOSSES, NEED)
		t.eq(#list, #GddTables.BOSSES, "boss count")
		local seen = {}
		for i, g in GddTables.BOSSES do
			local e = list[i]
			t.eq(field(e, NEED, `boss {i}`), g.need, `boss {i} {g.name} MP needed`)
			t.eq(field(e, COINS, `boss {i}`), g.coins, `boss {i} {g.name} coins/win`)
			t.eq(field(e, WORLD, `boss {i}`), g.world, `boss {i} {g.name} world`)
			local id = field(e, BOSS_ID, `boss {i}`)
			t.ok(type(id) == "string" and #id >= 1 and #id <= 32, `boss {i} id is a 1..32 char string`)
			t.ok(not seen[id], `boss id {id} unique`)
			seen[id] = true
		end
	end)

	-- QA-7 (build 1): BossService checks EconomyConfig's boss `world` against ZoneService's world, and
	-- ZoneService.isNearBoss resolves the stage through MapLayout.BOSS_IDS. A boss whose id or world differs
	-- between the two tables can never be fought. Same check runs without Studio: tests/static/check_boss_ids.py.
	t.test("BOSSES ids and worlds match MapLayout.BOSS_IDS (stage row order)", function()
		local MapLayout: any = TestKit.tryRequire(Shared, { "World", "MapLayout" })
		if MapLayout == nil then
			t.ok(false, "Shared.World.MapLayout not found")
			return
		end
		local layoutIds = MapLayout.BOSS_IDS
		t.eq(type(layoutIds), "table", "MapLayout.BOSS_IDS")
		local list = entries(E.BOSSES, NEED)
		local byWorld: { [number]: { string } } = {}
		for i, e in list do
			local world = field(e, WORLD, `boss {i}`)
			local id = field(e, BOSS_ID, `boss {i}`)
			byWorld[world] = byWorld[world] or {}
			table.insert(byWorld[world], id)
			t.eq(MapLayout.getBossWorld(id), world, `MapLayout.getBossWorld({id})`)
		end
		local layoutCount = 0
		for world, ids in layoutIds do
			layoutCount += #ids
			local config = byWorld[world] or {}
			t.eq(#config, #ids, `world {world} boss count`)
			for i, id in ids do
				t.eq(config[i], id, `world {world} stage {i} boss id`)
			end
		end
		t.eq(layoutCount, #list, "MapLayout boss count == EconomyConfig boss count")
		if type(E.BOSS_BY_ID) == "table" then
			for _, ids in layoutIds do
				for _, id in ids do
					t.ok(E.BOSS_BY_ID[id] ~= nil, `BOSS_BY_ID[{id}]`)
				end
			end
		end
	end)

	t.test("RANKS match GDD 7", function()
		local list = entries(E.RANKS, LIFETIME)
		t.eq(#list, #GddTables.RANKS, "rank count")
		for i, g in GddTables.RANKS do
			t.eq(field(list[i], LIFETIME, `rank {i}`), g.lifetime, `rank {i} {g.name} lifetime MP`)
		end
	end)

	t.test("rebirthCost(n) = 15000 x 3^(n-1) (GDD 4.5)", function()
		for n = 1, 12 do
			t.near(E.rebirthCost(n), GddTables.REBIRTH_BASE * 3 ^ (n - 1), `rebirthCost({n})`)
		end
	end)

	t.test("rebirthMult / coinRebirthMult (GDD 4.1)", function()
		for r = 0, 12 do
			t.near(E.rebirthMult(r), 1 + 0.5 * r, `rebirthMult({r})`)
			t.near(E.coinRebirthMult(r), 1 + 0.1 * r, `coinRebirthMult({r})`)
		end
	end)

	t.test("paidTierMult(0..5) = 1, 2, 4, 8, 16, 32", function()
		for tier = 0, 5 do
			t.eq(E.paidTierMult(tier), 2 ^ tier, `paidTierMult({tier})`)
		end
	end)

	t.test("petSlots: 3, +1 at R3, +1 at R8, +1 VIP (GDD 5)", function()
		t.eq(E.petSlots(0, false), 3, "R0")
		t.eq(E.petSlots(2, false), 3, "R2")
		t.eq(E.petSlots(3, false), 4, "R3")
		t.eq(E.petSlots(7, false), 4, "R7")
		t.eq(E.petSlots(8, false), 5, "R8")
		t.eq(E.petSlots(20, false), 5, "R20 (5 free max)")
		t.eq(E.petSlots(0, true), 4, "R0 VIP")
		t.eq(E.petSlots(8, true), 6, "R8 VIP")
	end)

	t.test("duelScore = taps x (1 + 0.03 x min(own, opp + 2)) (GDD 6)", function()
		t.near(E.duelScore(80, 1, 1), 80 * 1.03, "80 taps, rank 1 vs 1")
		t.near(E.duelScore(80, 12, 1), 80 * 1.09, "rank 12 vs 1 is capped at opp + 2")
		t.near(E.duelScore(50, 5, 12), 50 * 1.15, "rank 5 vs 12")
		t.near(E.duelScore(0, 12, 12), 0, "0 taps")
	end)

	t.test("M clamp binds only above the GDD theoretical max (GDD 4.1)", function()
		local maxM = E.PET_MULT_CAP * E.rebirthMult(10) * E.paidTierMult(5) * 1.25 * 2
		t.near(maxM, 12000, "theoretical max at R10")
		t.ok(E.M_CLAMP < maxM, "clamp below theoretical max")
	end)

	if type(E.EGGS) ~= "table" or next(E.EGGS) == nil then
		t.skip("EGGS weights match GDD 5", "EconomyConfig.EGGS empty (T-027, sprint 2)")
	else
		t.test("EGGS weights match GDD 5 and sum to 10,000", function()
			for _, g in GddTables.EGGS do
				local egg = E.EGGS[g.id]
				t.ok(egg ~= nil, `EGGS.{g.id} present`)
				local pets = field(egg, { "pets", "odds", "table" }, g.id)
				local got, want, sum = {}, {}, 0
				for _, p in pets do
					local w = field(p, { "weight" }, g.id)
					sum += w
					table.insert(got, w)
				end
				for _, p in g.pets do
					table.insert(want, p.weight)
				end
				table.sort(got)
				table.sort(want)
				t.eq(sum, 10000, `{g.id} weight sum`)
				t.eq(table.concat(got, ","), table.concat(want, ","), `{g.id} weights`)
			end
		end)
	end
end
