--!strict
-- Read-only adapter from the UI to shared config and the map (helper, not a controller). Owned by systems-programmer.
-- Every number the UI shows comes from Gameplay/EconomyConfig (gameplay-programmer, T-006); every map lookup goes
-- through World/MapLayout (world-programmer, T-016), the only code that knows tag and attribute names.
-- Both modules are written in parallel this sprint, so this file is nil-safe: if a module, table or function is
-- missing, the UI hides the element that needs it instead of erroring. All field names live here only, so a
-- mismatch at merge is a one-file fix (Contract request CR-4 in the T-014 summary asks for these names).
--
-- Expected (CR-4):
--   EconomyConfig.BOSSES = { { id, name, worldId, mpNeed, coins } } (weakest first; a map keyed by id also works)
--   EconomyConfig.TOOLS  = { { name, mpPerTap, cost, worldId } } (index = tool index 1..12)
--   EconomyConfig.RANKS  = { { name, lifetimeMp } } (index = rank 1..12)
--   EconomyConfig.TAP_CAP_PER_SEC, EconomyConfig.INTERACT_RANGE
--   MapLayout.getBossStage(bossId: string): Instance?  (Model or BasePart, nil while streamed out)
--   MapLayout.positionOf(inst: Instance?): Vector3?
--   MapLayout.getShopKindOf(inst): "Tools" | "Robux" | nil (prompts are matched by walking their ancestors)

local ReplicatedStorage = game:GetService("ReplicatedStorage")

export type Boss = { id: string, name: string, worldId: number, need: number, coins: number }
export type Tool = { index: number, name: string, power: number, cost: number, worldId: number }
export type Rank = { index: number, name: string, need: number }
export type Pod = { index: number, name: string, mpPerSec: number, cost: number, worldId: number }
export type EggPet = { petId: string, weight: number }
export type Egg = {
	id: string,
	name: string,
	worldId: number,
	currency: string, -- "Coins" | "Robux"
	price: number,
	pets: { EggPet }, -- same table, same order the server rolls (architecture 4b)
	oddsValid: boolean, -- weights are whole, positive and sum to ODDS_TOTAL
	pityAt: number?, -- Robux eggs: every Nth hatch with no Legendary+ is forced (GDD 5); nil = no pity
}
export type Pet = { id: string, name: string, rarity: string, bonus: number }

local GameData = {}

local DEFAULT_TAP_CAP = 12 -- architecture 1c; used only if EconomyConfig is missing
local DEFAULT_RANGE = 20
-- GDD 4.5, 4.6 and 5 fallbacks, used only if EconomyConfig lacks the constant.
local DEFAULT_AUTO_TAP_RANK = 3
local DEFAULT_AUTO_MOG_REBIRTHS = 1
local DEFAULT_HATCH3_REBIRTHS = 2

local function loadModule(folderName: string, moduleName: string): any
	local shared = ReplicatedStorage:WaitForChild("Shared", 10)
	local folder = shared and shared:FindFirstChild(folderName)
	local module = folder and folder:FindFirstChild(moduleName)
	if module and module:IsA("ModuleScript") then
		local ok, result = pcall(require, module)
		if ok then
			return result
		end
		warn(`GameData: {moduleName} failed to load: {result}`)
	end
	return nil
end

local economy: any = nil
local mapLayout: any = nil
local loaded = false

local function ensure()
	if not loaded then
		loaded = true
		economy = loadModule("Gameplay", "EconomyConfig")
		mapLayout = loadModule("World", "MapLayout")
		if economy == nil then
			warn("GameData: EconomyConfig not found; boss/tool/rank UI hidden")
		end
	end
end

local function pick(entry: any, names: { string }): any
	for _, name in names do
		local value = entry[name]
		if value ~= nil then
			return value
		end
	end
	return nil
end

local function num(value: any, default: number): number
	if type(value) == "number" and value == value then
		return value
	end
	return default
end

local bossCache: { Boss }? = nil
local toolCache: { Tool }? = nil
local rankCache: { Rank }? = nil
local podCache: { Pod }? = nil

function GameData.bosses(): { Boss }
	ensure()
	if bossCache then
		return bossCache
	end
	local list: { Boss } = {}
	local source = economy and economy.BOSSES
	if type(source) == "table" then
		for key, entry in source do
			if type(entry) == "table" then
				local id = pick(entry, { "id", "bossId" }) or (if type(key) == "string" then key else nil)
				local need = pick(entry, { "mpNeed", "need", "mpNeeded" })
				if type(id) == "string" and type(need) == "number" then
					table.insert(list, {
						id = id,
						name = tostring(pick(entry, { "name", "displayName" }) or id),
						worldId = num(pick(entry, { "worldId", "world" }), 1),
						need = need,
						coins = num(pick(entry, { "coins", "coinsPerWin" }), 0),
					})
				end
			end
		end
	end
	table.sort(list, function(a, b)
		return a.need < b.need
	end)
	bossCache = list
	return list
end

function GameData.bossesInWorld(worldId: number): { Boss }
	local out = {}
	for _, boss in GameData.bosses() do
		if boss.worldId == worldId then
			table.insert(out, boss)
		end
	end
	return out
end

function GameData.tools(): { Tool }
	ensure()
	if toolCache then
		return toolCache
	end
	local list: { Tool } = {}
	local source = economy and economy.TOOLS
	if type(source) == "table" then
		for index, entry in ipairs(source) do
			if type(entry) == "table" then
				table.insert(list, {
					index = index,
					name = tostring(pick(entry, { "name", "displayName" }) or `Tool {index}`),
					power = num(pick(entry, { "mpPerTap", "power" }), 0),
					cost = num(pick(entry, { "cost", "price" }), 0),
					worldId = num(pick(entry, { "worldId", "world" }), 1),
				})
			end
		end
	end
	toolCache = list
	return list
end

function GameData.ranks(): { Rank }
	ensure()
	if rankCache then
		return rankCache
	end
	local list: { Rank } = {}
	local source = economy and economy.RANKS
	if type(source) == "table" then
		for index, entry in ipairs(source) do
			if type(entry) == "table" then
				table.insert(list, {
					index = index,
					name = tostring(pick(entry, { "name", "displayName" }) or `Rank {index}`),
					need = num(pick(entry, { "lifetimeMp", "need" }), 0),
				})
			end
		end
	end
	rankCache = list
	return list
end

function GameData.pods(): { Pod }
	ensure()
	if podCache then
		return podCache
	end
	local list: { Pod } = {}
	local source = economy and economy.PODS
	if type(source) == "table" then
		for index, entry in ipairs(source) do
			if type(entry) == "table" then
				table.insert(list, {
					index = index,
					name = tostring(pick(entry, { "name", "displayName" }) or `Pod {index}`),
					mpPerSec = num(pick(entry, { "mpPerSec" }), 0),
					cost = num(pick(entry, { "cost" }), 0),
					worldId = num(pick(entry, { "world", "worldId" }), 1),
				})
			end
		end
	end
	podCache = list
	return list
end

-- Calls a pure EconomyConfig formula; nil if it is missing or fails.
local function formula(name: string, ...: any): number?
	ensure()
	local fn = economy and economy[name]
	if type(fn) ~= "function" then
		return nil
	end
	local ok, value = pcall(fn, ...)
	if ok and type(value) == "number" and value == value then
		return value
	end
	return nil
end

-- Coins for rebirth number `n` (1 = first). Display only: the server's RebirthCost attribute wins.
function GameData.rebirthCost(n: number): number?
	return formula("rebirthCost", n)
end

function GameData.rebirthMult(rebirths: number): number
	return formula("rebirthMult", rebirths) or (1 + 0.5 * rebirths)
end

function GameData.coinRebirthMult(rebirths: number): number
	return formula("coinRebirthMult", rebirths) or (1 + 0.1 * rebirths)
end

function GameData.autoTapRank(): number
	ensure()
	return num(economy and economy.AUTO_TAP_FREE_RANK, DEFAULT_AUTO_TAP_RANK)
end

function GameData.autoMogRebirths(): number
	ensure()
	return num(economy and economy.AUTO_MOG_REBIRTHS, DEFAULT_AUTO_MOG_REBIRTHS)
end

-- Hatch x3 unlock (GDD 5: Rebirth 2): EconomyConfig.HATCH_MULTI_REBIRTHS (CR-S2b, D-051).
function GameData.hatchThreeRebirths(): number
	ensure()
	return num(economy and economy.HATCH_MULTI_REBIRTHS, DEFAULT_HATCH3_REBIRTHS)
end

-- Rebirth counts that each add a pet slot (GDD 5: 3 and 8).
function GameData.petSlotRebirths(): { number }
	ensure()
	local source = economy and economy.PET_SLOT_REBIRTHS
	local out = {}
	if type(source) == "table" then
		for _, value in ipairs(source) do
			if type(value) == "number" then
				table.insert(out, value)
			end
		end
	end
	return out
end

local DEFAULT_ODDS_TOTAL = 10000
local DEFAULT_INVENTORY_CAP = 60
local DEFAULT_INVENTORY_HARD_CAP = 66

function GameData.oddsTotal(): number
	ensure()
	return num(economy and economy.ODDS_TOTAL, DEFAULT_ODDS_TOTAL)
end

function GameData.inventoryCap(): number
	ensure()
	return num(economy and economy.INVENTORY_CAP, DEFAULT_INVENTORY_CAP)
end

-- Most pets a profile can hold (paid receipts may pass INVENTORY_CAP, architecture 4b). Bounds PetInventory.
function GameData.inventoryHardCap(): number
	ensure()
	return num(economy and economy.INVENTORY_HARD_CAP, DEFAULT_INVENTORY_HARD_CAP)
end

-- Egg `eggId` from EconomyConfig.EGGS (T-027), read as-is: the UI shows exactly the weights the server rolls.
function GameData.egg(eggId: string): Egg?
	ensure()
	local source = economy and economy.EGGS
	local entry = if type(source) == "table" then source[eggId] else nil
	if type(entry) ~= "table" or type(entry.pets) ~= "table" then
		return nil
	end
	local pets: { EggPet } = {}
	local sum = 0
	local valid = true
	for _, row in ipairs(entry.pets) do
		if type(row) == "table" and type(row.petId) == "string" and type(row.weight) == "number" then
			table.insert(pets, { petId = row.petId, weight = row.weight })
			sum += row.weight
			if row.weight <= 0 or row.weight % 1 ~= 0 then
				valid = false
			end
		else
			valid = false
		end
	end
	return {
		id = eggId,
		name = tostring(pick(entry, { "name" }) or eggId),
		worldId = num(pick(entry, { "world", "worldId" }), 1),
		currency = tostring(pick(entry, { "currency" }) or "Coins"),
		price = num(pick(entry, { "price" }), 0),
		pets = pets,
		oddsValid = valid and #pets > 0 and sum == GameData.oddsTotal(),
		pityAt = if type(entry.pityAt) == "number" and entry.pityAt >= 2 then entry.pityAt else nil,
	}
end

-- Forced pity roll weights (Legendary, Mythic) out of ODDS_TOTAL: 9000 / 1000 (GDD 5, architecture 4b).
function GameData.pityWeights(): (number, number)
	ensure()
	return num(economy and economy.PITY_LEGENDARY_WEIGHT, 9000),
		num(economy and economy.PITY_MYTHIC_WEIGHT, 1000)
end

-- Pet `petId` from EconomyConfig.PETS; nil if unknown.
function GameData.pet(petId: string): Pet?
	ensure()
	local source = economy and economy.PETS
	local entry = if type(source) == "table" then source[petId] else nil
	if type(entry) ~= "table" then
		return nil
	end
	return {
		id = petId,
		name = tostring(pick(entry, { "name" }) or petId),
		rarity = tostring(pick(entry, { "rarity" }) or "Common"),
		bonus = num(pick(entry, { "bonus" }), 0),
	}
end

function GameData.tapCapPerSec(): number
	ensure()
	return num(economy and economy.TAP_CAP_PER_SEC, DEFAULT_TAP_CAP)
end

function GameData.interactRange(): number
	ensure()
	return num(economy and economy.INTERACT_RANGE, DEFAULT_RANGE)
end

-- The boss's `BossStage` map item: a Model or a BasePart (CR-4), nil while streamed out. Use `positionOf` for
-- its position, never `.Position`.
function GameData.bossStage(bossId: string): Instance?
	ensure()
	local fn = mapLayout and mapLayout.getBossStage
	if type(fn) ~= "function" then
		return nil
	end
	local ok, stage = pcall(fn, bossId)
	if ok and typeof(stage) == "Instance" then
		return stage
	end
	return nil
end

-- World position of a map item (BasePart position, Model pivot) through MapLayout.positionOf; nil if unknown.
function GameData.positionOf(inst: Instance?): Vector3?
	ensure()
	local fn = mapLayout and mapLayout.positionOf
	if inst == nil or type(fn) ~= "function" then
		return nil
	end
	local ok, pos = pcall(fn, inst)
	if ok and typeof(pos) == "Vector3" then
		return pos
	end
	return nil
end

-- A BasePart to hang an Attachment on: the item itself, a Model's PrimaryPart, or its first streamed-in part.
function GameData.anchorPartOf(inst: Instance?): BasePart?
	if inst == nil then
		return nil
	end
	if inst:IsA("BasePart") then
		return inst
	end
	if inst:IsA("Model") then
		return inst.PrimaryPart or inst:FindFirstChildWhichIsA("BasePart", true)
	end
	return nil
end

-- True if `prompt` belongs to a shop stand of `kind` ("Tools" or "Robux"). Walks the prompt's ancestors and asks
-- MapLayout which shop each one is (architecture 1f, CR-4: there is no `getShopStands`). Stops at Workspace.
function GameData.isShopPrompt(prompt: ProximityPrompt, kind: string): boolean
	ensure()
	local fn = mapLayout and mapLayout.getShopKindOf
	if type(fn) ~= "function" then
		return false
	end
	local node: Instance? = prompt.Parent
	while node ~= nil and node ~= workspace do
		local ok, shop = pcall(fn, node)
		if ok and shop ~= nil then
			return shop == kind
		end
		node = node.Parent
	end
	return false
end

-- The EggId of the EggStand that holds `prompt` (walks ancestors with MapLayout.getEggIdOf, 1f), or nil.
function GameData.eggIdOfPrompt(prompt: ProximityPrompt): string?
	ensure()
	local fn = mapLayout and mapLayout.getEggIdOf
	if type(fn) ~= "function" then
		return nil
	end
	local node: Instance? = prompt.Parent
	while node ~= nil and node ~= workspace do
		local ok, eggId = pcall(fn, node)
		if ok and type(eggId) == "string" then
			return eggId
		end
		node = node.Parent
	end
	return nil
end

-- Egg stand position (the streamed-in stand, else MapLayout's layout fallback), or nil.
function GameData.eggStandPosition(eggId: string): Vector3?
	ensure()
	local fn = mapLayout and mapLayout.getEggStandPosition
	if type(fn) ~= "function" then
		return nil
	end
	local ok, pos = pcall(fn, eggId)
	if ok and typeof(pos) == "Vector3" then
		return pos
	end
	return nil
end

return table.freeze(GameData)
