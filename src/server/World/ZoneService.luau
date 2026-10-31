--!strict
-- ZoneService (T-016 core). Owned by world-programmer. Server only.
-- Current world per player (`WorldId`, `World2Unlocked`, `CurrentPod` attributes), spawn placement,
-- boss-stage / stand lookup and server distance checks. Map names come only from Shared.World.MapLayout.
-- Later tickets: pod presence + portal + isNearEggStand (T-038), rings + teleportToWorld (T-059).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local MapLayout = require(Shared:WaitForChild("World"):WaitForChild("MapLayout"))
local Types = require(Shared:WaitForChild("Contracts"):WaitForChild("Types"))

local PlayerAttr = Types.PlayerAttr

-- INTERACT_RANGE lives in Gameplay/EconomyConfig (architecture 1c). Read it if that module exists,
-- else use the documented default, so this module works before EconomyConfig is merged.
local DEFAULT_INTERACT_RANGE = 20
local function readInteractRange(): number
	local gameplay = Shared:FindFirstChild("Gameplay")
	local module = gameplay and gameplay:FindFirstChild("EconomyConfig")
	if module and module:IsA("ModuleScript") then
		local ok, config = pcall(require :: any, module)
		if ok and typeof(config) == "table" then
			local range = config.INTERACT_RANGE
			if typeof(range) == "number" and range > 0 and range < 200 then
				return range
			end
		end
	end
	return DEFAULT_INTERACT_RANGE
end

-- Extra studs on top of INTERACT_RANGE for server lag and stage size (player stands at the stage
-- edge, the anchor is its centre). Kept small so a client cannot fight from across the hub.
local RANGE_SLACK = 6
local MAX_BOSS_ID_LEN = 32
local SPAWN_SNAP_DISTANCE = 30 -- re-place a new character only if Roblox spawned it this far away
local SPAWN_SPREAD = 4 -- random XZ offset so players do not stack on one spot
local ROOT_WAIT_SEC = 5

type DataServiceLike = {
	ProfileLoaded: RBXScriptSignal,
	getData: (player: Player) -> Types.ProfileData?,
}

local ZoneService = {}

local worldChangedEvent: BindableEvent
local podChangedEvent: BindableEvent
local interactRange = DEFAULT_INTERACT_RANGE
local worldOf: { [Player]: Types.WorldId } = {}
local podOf: { [Player]: number } = {}
local dataService: DataServiceLike? = nil
local warnedMissing: { [string]: true } = {} -- map ids already reported missing (warn once each)

-- QA-9: the layout fallback hides builder mistakes, so report each missing map id once.
local function warnMissingOnce(kind: string, id: string)
	local key = `{kind}:{id}`
	if warnedMissing[key] then
		return
	end
	warnedMissing[key] = true
	warn(`[ZoneService] No {kind} tagged with id "{id}" in Workspace; using the MapLayout fallback position`)
end

local function rootPart(player: Player): BasePart?
	local character = player.Character
	if character == nil then
		return nil
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid == nil or humanoid.Health <= 0 then
		return nil
	end
	return humanoid.RootPart
end

local function findDataService(): DataServiceLike?
	-- World may require Data (architecture 1a). Looked up by name so World runs before Data merges.
	local serverRoot = script.Parent and script.Parent.Parent
	local dataFolder = serverRoot and serverRoot:FindFirstChild("Data")
	local module = dataFolder and dataFolder:FindFirstChild("DataService")
	if module and module:IsA("ModuleScript") then
		local ok, service = pcall(require :: any, module)
		if ok and typeof(service) == "table" and typeof(service.getData) == "function" then
			return service :: DataServiceLike
		end
	end
	warn("[ZoneService] DataService not found; World2Unlocked stays false")
	return nil
end

local function setWorld(player: Player, worldId: Types.WorldId)
	if not MapLayout.isValidWorld(worldId) then
		return
	end
	local previous = worldOf[player]
	worldOf[player] = worldId
	player:SetAttribute(PlayerAttr.WorldId, worldId)
	if previous ~= nil and previous ~= worldId then
		worldChangedEvent:Fire(player, worldId)
	end
end

local function applyProfile(player: Player, data: Types.ProfileData?)
	if data == nil or player.Parent ~= Players then
		return
	end
	player:SetAttribute(PlayerAttr.World2Unlocked, data.world2Unlocked == true)
end

-- Puts a fresh character on its world's spawn, facing the first boss. Yields (waits for the root).
local function placeCharacter(player: Player, character: Model)
	local humanoid = character:WaitForChild("Humanoid", ROOT_WAIT_SEC)
	local root = character:WaitForChild("HumanoidRootPart", ROOT_WAIT_SEC)
	if humanoid == nil or root == nil or not root:IsA("BasePart") then
		return
	end
	if player.Character ~= character or not character:IsDescendantOf(workspace) then
		return
	end
	local spawnCf = MapLayout.getSpawnCFrame(ZoneService.getWorld(player))
	if spawnCf == nil then
		return
	end
	if (root.Position - spawnCf.Position).Magnitude <= SPAWN_SNAP_DISTANCE then
		return -- Roblox already used the right SpawnLocation
	end
	local spread =
		Vector3.new((math.random() * 2 - 1) * SPAWN_SPREAD, 0, (math.random() * 2 - 1) * SPAWN_SPREAD)
	character:PivotTo(spawnCf + spread)
end

local function onPlayerAdded(player: Player)
	if worldOf[player] ~= nil then
		return -- already handled (joined between Connect and GetPlayers)
	end
	-- Everyone joins in Glow Town (World 2 is entered through the portal each session).
	setWorld(player, 1)
	podOf[player] = 0
	player:SetAttribute(PlayerAttr.CurrentPod, 0)
	player:SetAttribute(PlayerAttr.World2Unlocked, false)
	-- Make the matching SpawnLocation the respawn point when builder used one.
	local spawnInst = MapLayout.getSpawn(ZoneService.getWorld(player))
	if spawnInst and spawnInst:IsA("SpawnLocation") then
		player.RespawnLocation = spawnInst
	end
	player.CharacterAdded:Connect(function(character)
		placeCharacter(player, character)
	end)
	if player.Character then
		task.spawn(placeCharacter, player, player.Character)
	end
	if dataService then
		applyProfile(player, dataService.getData(player))
	end
end

local function onPlayerRemoving(player: Player)
	worldOf[player] = nil
	podOf[player] = nil
end

-- Public API ------------------------------------------------------------------------------------

ZoneService.WorldChanged = (nil :: any) :: RBXScriptSignal -- (player: Player, worldId: T.WorldId)
ZoneService.PodChanged = (nil :: any) :: RBXScriptSignal -- (player: Player, podIndex: number) 0 = none

function ZoneService:Init()
	worldChangedEvent = Instance.new("BindableEvent")
	podChangedEvent = Instance.new("BindableEvent")
	ZoneService.WorldChanged = worldChangedEvent.Event
	ZoneService.PodChanged = podChangedEvent.Event
	interactRange = readInteractRange()
end

function ZoneService:Start()
	dataService = findDataService()
	if dataService then
		dataService.ProfileLoaded:Connect(function(player: Player, data: Types.ProfileData)
			applyProfile(player, data)
		end)
	end
	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)
	for _, player in Players:GetPlayers() do
		task.spawn(onPlayerAdded, player)
	end
end

function ZoneService.getWorld(player: Player): Types.WorldId
	return worldOf[player] or 1
end

-- Pod presence arrives in T-038; until then nobody is in a pod.
function ZoneService.getPod(player: Player): number
	return podOf[player] or 0
end

-- Interaction range used by isNearBoss / isNearEggStand (EconomyConfig.INTERACT_RANGE).
function ZoneService.getInteractRange(): number
	return interactRange
end

-- Root position of a live character, or nil (no character, dead, or not loaded).
function ZoneService.getCharacterPosition(player: Player): Vector3?
	local root = rootPart(player)
	return if root then root.Position else nil
end

-- World id of a boss, from the layout (nil for an unknown id).
function ZoneService.getBossWorld(bossId: string): Types.WorldId?
	if typeof(bossId) ~= "string" or #bossId > MAX_BOSS_ID_LEN then
		return nil
	end
	return MapLayout.getBossWorld(bossId)
end

-- Server-side stage position: the BossStage part, else the layout fallback.
function ZoneService.getBossStagePosition(bossId: string): Vector3?
	if typeof(bossId) ~= "string" or #bossId > MAX_BOSS_ID_LEN then
		return nil
	end
	if MapLayout.getBossWorld(bossId) ~= nil and MapLayout.getBossStage(bossId) == nil then
		warnMissingOnce("BossStage", bossId) -- missing or mistyped BossId (QA-9)
	end
	return MapLayout.getBossStagePosition(bossId)
end

function ZoneService.getShopStandPosition(worldId: Types.WorldId, shop: MapLayout.ShopKind): Vector3?
	return MapLayout.getShopStandPosition(worldId, shop)
end

-- True when the player is alive, in the boss's world, and within INTERACT_RANGE (+ slack) of the
-- stage. Safe to call with untrusted input: returns false for anything malformed.
function ZoneService.isNearBoss(player: Player, bossId: string): boolean
	if typeof(player) ~= "Instance" or not player:IsA("Player") then
		return false
	end
	local bossWorld = ZoneService.getBossWorld(bossId)
	if bossWorld == nil or bossWorld ~= ZoneService.getWorld(player) then
		return false
	end
	local stage = MapLayout.getBossStage(bossId)
	if stage ~= nil then
		local stageWorld = MapLayout.getWorldIdOf(stage)
		if stageWorld ~= nil and stageWorld ~= bossWorld then
			warn(`[ZoneService] BossStage "{bossId}" has WorldId {stageWorld}, layout says {bossWorld}`)
			return false
		end
	end
	local stagePos = ZoneService.getBossStagePosition(bossId)
	local playerPos = ZoneService.getCharacterPosition(player)
	if stagePos == nil or playerPos == nil then
		return false
	end
	return (playerPos - stagePos).Magnitude <= interactRange + RANGE_SLACK
end

return ZoneService
