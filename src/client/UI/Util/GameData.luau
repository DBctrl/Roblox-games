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
--   MapLayout.getBossStage(bossId: string): BasePart?            (nil while streamed out)
--   MapLayout.getShopKindOf(inst): "Tools" | "Robux" | nil (prompts are matched by walking their ancestors)

local ReplicatedStorage = game:GetService("ReplicatedStorage")

export type Boss = { id: string, name: string, worldId: number, need: number, coins: number }
export type Tool = { index: number, name: string, power: number, cost: number, worldId: number }
export type Rank = { index: number, name: string, need: number }

local GameData = {}

local DEFAULT_TAP_CAP = 12 -- architecture 1c; used only if EconomyConfig is missing
local DEFAULT_RANGE = 20

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

function GameData.tapCapPerSec(): number
	ensure()
	return num(economy and economy.TAP_CAP_PER_SEC, DEFAULT_TAP_CAP)
end

function GameData.interactRange(): number
	ensure()
	return num(economy and economy.INTERACT_RANGE, DEFAULT_RANGE)
end

function GameData.bossStage(bossId: string): BasePart?
	ensure()
	local fn = mapLayout and mapLayout.getBossStage
	if type(fn) ~= "function" then
		return nil
	end
	local ok, part = pcall(fn, bossId)
	if ok and typeof(part) == "Instance" and part:IsA("BasePart") then
		return part
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

return table.freeze(GameData)
