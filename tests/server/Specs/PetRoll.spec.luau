--!strict
-- T-046: egg odds and pet-roll distribution. Owned by qa.
-- Written against docs/architecture.md v1.2 (1c EGGS/PETS, 4b roll rules) and GDD rev 2 section 5, not against
-- code. Pure: needs no Player, so it runs in Studio Run mode (F8). SKIPs while T-027 (egg data) or the roller
-- (T-028) is not merged.
--
-- The server roller is reached through a pure helper, probed in this order (QA-F7 asks gameplay to expose one):
--   1. ServerScriptService.Server.Gameplay.Util.PetRoll.pick(pets: { EggPet }, rng: Random) -> PetId
--   2. PetService.rollPet(eggId: EggId, rng: Random) -> PetId
-- A result that is a table is read as `.petId` or `.id`.
-- Pass rule per egg over N = 100,000 rolls (T-046): chi-square below the p = 0.001 critical value AND every pet's
-- share within 5 standard errors of its listed odds. A seeded reference roller runs first, so a FAIL on the real
-- roller is not a harness bug.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local QaTests = ReplicatedStorage:WaitForChild("QaTests")
local GddEggs = require(QaTests:WaitForChild("Fixtures"):WaitForChild("GddEggs"))
local TestKit = require(QaTests:WaitForChild("TestKit"))

local N = 100000
local SEED = 46046
-- Chi-square critical values at p = 0.001, by degrees of freedom (pets - 1).
local CHI2_CRIT = { 10.828, 13.816, 16.266, 18.467, 20.515, 22.458, 24.322, 26.124, 27.877, 29.588 }
local SIGMAS = 5

type EggPet = { petId: string, weight: number }
type Roller = (eggId: string, pets: { EggPet }, rng: Random) -> any

local function sortedIds(map: { [string]: any }): { string }
	local ids = {}
	for id in map do
		table.insert(ids, id)
	end
	table.sort(ids)
	return ids
end

-- Reference roller: one integer in [1, total], walk the cumulative weights.
local function referencePick(pets: { EggPet }, rng: Random): string
	local total = 0
	for _, p in pets do
		total += p.weight
	end
	local r = rng:NextInteger(1, total)
	for _, p in pets do
		r -= p.weight
		if r <= 0 then
			return p.petId
		end
	end
	return pets[#pets].petId
end

local function asPetId(result: any): any
	if type(result) == "table" then
		return result.petId or result.id
	end
	return result
end

-- Rolls `N` times and returns (ok, detail). Checks unknown results, chi-square and per-pet tolerance.
local function checkDistribution(
	eggId: string,
	pets: { EggPet },
	total: number,
	roll: Roller
): (boolean, string)
	local rng = Random.new(SEED)
	local counts: { [string]: number } = {}
	local weightOf: { [string]: number } = {}
	for _, p in pets do
		counts[p.petId] = 0
		weightOf[p.petId] = (weightOf[p.petId] or 0) + p.weight
	end
	for _ = 1, N do
		local id = asPetId(roll(eggId, pets, rng))
		if type(id) ~= "string" or counts[id] == nil then
			return false, `{eggId}: roll returned {tostring(id)}, which is not in the egg's table`
		end
		counts[id] += 1
	end
	local chi2, worst, worstLine = 0, 0, ""
	local k = 0
	for id, w in weightOf do
		k += 1
		local p = w / total
		local expected = N * p
		local observed = counts[id]
		chi2 += (observed - expected) ^ 2 / expected
		local z = math.abs(observed - expected) / math.sqrt(N * p * (1 - p))
		if z > worst then
			worst = z
			worstLine = `{id} {observed}/{N} vs {string.format("%.3f", p * 100)}%`
		end
	end
	local crit = CHI2_CRIT[k - 1] or math.huge
	local detail = `{eggId}: chi2 {string.format("%.2f", chi2)} (crit {crit}, df {k - 1}), worst `
		.. `{string.format("%.2f", worst)} sigma ({worstLine})`
	return chi2 < crit and worst <= SIGMAS, detail
end

-- Finds the server roller (see header). Returns nil and a reason if none is exposed yet.
local function findRoller(Server: Instance?): (Roller?, string)
	local PetRoll = TestKit.tryRequire(Server, { "Gameplay", "Util", "PetRoll" }) :: any
	if PetRoll and type(PetRoll.pick) == "function" then
		return function(_eggId, pets, rng)
			return PetRoll.pick(pets, rng)
		end,
			"Gameplay/Util/PetRoll.pick"
	end
	local PetService = TestKit.tryRequire(Server, { "Gameplay", "PetService" }) :: any
	if PetService and type(PetService.rollPet) == "function" then
		return function(eggId, _pets, rng)
			return PetService.rollPet(eggId, rng)
		end,
			"PetService.rollPet"
	end
	if PetService then
		return nil, "PetService has no pure roll helper (QA-F7: expose Util/PetRoll.pick(pets, rng))"
	end
	return nil, "PetService (T-028) not merged"
end

return function(t: TestKit.Suite)
	local Shared = ReplicatedStorage:FindFirstChild("Shared")
	local Server = ServerScriptService:FindFirstChild("Server")
	local E = TestKit.tryRequire(Shared, { "Gameplay", "EconomyConfig" }) :: any
	if E == nil then
		t.skip("all pet-roll checks", "Shared.Gameplay.EconomyConfig not found (T-006 not merged)")
		return
	end
	local eggs: { [string]: any } = if type(E.EGGS) == "table" then E.EGGS else {}
	local petsById: { [string]: any } = if type(E.PETS) == "table" then E.PETS else {}
	local eggIds = sortedIds(eggs)
	local total = E.ODDS_TOTAL

	t.test("ODDS_TOTAL is 10,000 (0.5% = 50, architecture 4b)", function()
		t.eq(total, 10000, "EconomyConfig.ODDS_TOTAL")
	end)

	t.test("coin eggs stay open to everyone (option A, D-021)", function()
		t.eq(E.COIN_EGGS_POLICY_GATED, false, "EconomyConfig.COIN_EGGS_POLICY_GATED")
	end)

	if #eggIds == 0 then
		t.skip("egg odds and roll distribution", "EconomyConfig.EGGS is empty (T-027 not merged)")
		return
	end

	t.test("lean v1 eggs are present: BasicEgg, ShinyEgg, StarEgg, GalaxyEgg (T-027, D-034)", function()
		for _, id in { "BasicEgg", "ShinyEgg", "StarEgg", "GalaxyEgg" } do
			t.ok(eggs[id] ~= nil, `EGGS.{id} missing`)
		end
	end)

	for _, eggId in eggIds do
		local egg = eggs[eggId]
		local gdd = GddEggs[eggId]

		t.test(`{eggId}: odds sum to 100% in whole-number weights of known pets`, function()
			t.ok(type(egg.pets) == "table" and #egg.pets > 0, `{eggId}.pets is a non-empty array`)
			local sum = 0
			local seen: { [string]: boolean } = {}
			for i, entry in egg.pets do
				t.ok(type(entry.petId) == "string", `{eggId}.pets[{i}].petId is a string`)
				t.ok(petsById[entry.petId] ~= nil, `{eggId}.pets[{i}].petId "{entry.petId}" is in PETS`)
				t.ok(not seen[entry.petId], `{eggId}: pet {entry.petId} listed once`)
				seen[entry.petId] = true
				local w = entry.weight
				t.ok(
					type(w) == "number" and w > 0 and w % 1 == 0,
					`{eggId}.pets[{i}].weight is a whole number > 0`
				)
				sum += w
			end
			t.eq(sum, total, `{eggId} weight sum`)
			t.near(sum / total * 100, 100, `{eggId} odds in percent`, 1e-9)
		end)

		if gdd == nil then
			t.test(`{eggId}: is a GDD section 5 egg`, function()
				error(`{eggId} is not in GDD rev 2 section 5 (fixture GddEggs)`)
			end)
		else
			t.test(`{eggId}: pets, rarities, bonuses and odds match GDD section 5`, function()
				t.eq(egg.currency, gdd.currency, `{eggId}.currency`)
				if gdd.currency == "Coins" then
					t.eq(egg.price, gdd.price, `{eggId}.price (coins)`)
				end
				-- every egg, Robux eggs too: GDD rev 3 (D-058) moved the Galaxy Egg to World 1
				t.eq(egg.world, gdd.world, `{eggId}.world`)
				t.eq(#egg.pets, #gdd.pets, `{eggId} pet count`)
				for i, row in gdd.pets do
					local entry = egg.pets[i]
					local pet = entry and petsById[entry.petId]
					t.ok(pet ~= nil, `{eggId}.pets[{i}] ({row.name}) exists`)
					t.eq(pet.name, row.name, `{eggId}.pets[{i}].name (GDD order)`)
					t.eq(pet.rarity, row.rarity, `{row.name} rarity`)
					t.near(pet.bonus, row.bonus, `{row.name} bonus`, 1e-9)
					t.eq(entry.weight, math.round(row.pct * total / 100), `{row.name} weight ({row.pct}%)`)
				end
			end)

			t.test(`{eggId}: restrictedGrant only on Robux eggs, and it is the GDD fixed pet`, function()
				if gdd.currency == "Robux" then
					local grant = egg.restrictedGrant
					t.ok(
						type(grant) == "string" and petsById[grant] ~= nil,
						`{eggId}.restrictedGrant is a PETS id`
					)
					t.eq(petsById[grant].name, gdd.restrictedGrant, `{eggId}.restrictedGrant pet name`)
					local inTable = false
					for _, entry in egg.pets do
						inTable = inTable or entry.petId == grant
					end
					t.ok(inTable, `{eggId}.restrictedGrant is one of the egg's disclosed pets`)
				else
					t.eq(egg.restrictedGrant, nil, `{eggId}.restrictedGrant (coin eggs have none)`)
				end
			end)
		end

		t.test(`{eggId}: reference roller over {N} rolls fits the weights (harness self-test)`, function()
			local ok, detail = checkDistribution(eggId, egg.pets, total, function(_id, pets, rng)
				return referencePick(pets, rng)
			end)
			t.ok(ok, detail)
		end)
	end

	local roller, source = findRoller(Server)
	if roller == nil then
		t.skip(`server roller distribution over {N} rolls per egg`, source)
		return
	end
	for _, eggId in eggIds do
		t.test(`{eggId}: server roller ({source}) over {N} rolls matches the listed odds`, function()
			local ok, detail = checkDistribution(eggId, eggs[eggId].pets, total, roller :: Roller)
			t.ok(ok, detail)
		end)
	end
end
