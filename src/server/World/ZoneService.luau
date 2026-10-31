--!strict
-- ZoneService (T-016 core). Owned by world-programmer. Server only.
-- Current world per player (`WorldId`, `World2Unlocked`, `CurrentPod` attributes), spawn placement,
-- boss-stage / stand lookup and server distance checks. Map names come only from Shared.World.MapLayout.
-- T-038: server pod presence (`CurrentPod`, `PodChanged`), the World 2 portal sign (Touched shows
-- "World 2 coming Saturday!" and never teleports; teleport = T-092) and isNearEggStand.
-- Later tickets: rings + teleportToWorld (T-059).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local MapLayout = require(Shared:WaitForChild("World"):WaitForChild("MapLayout"))
local Remotes = require(Shared:WaitForChild("Contracts"):WaitForChild("Remotes"))
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
local MAX_EGG_ID_LEN = 32
local POD_CHECK_INTERVAL = 0.5 -- seconds between server pod presence checks
local POD_PAD = 1 -- studs of slack around each pod box
local MAX_POD_INDEX = 7
local PORTAL_PAD = 6 -- touching player's root must be this close to the portal box (anti-spoof)
local PORTAL_NOTICE_COOLDOWN = 5 -- seconds between portal notices per player
local PORTAL_NOTICE_TEXT = "World 2 coming Saturday!"

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
local podParts: { [Instance]: true } = {} -- tagged Pod items in Workspace (the server sees all)
local portalConns: { [Instance]: { RBXScriptConnection } } = {}
local lastPortalNotice: { [Player]: number } = {}
local notifyRemote: RemoteEvent? = nil
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
	lastPortalNotice[player] = nil
end

-- Pod presence ----------------------------------------------------------------------------------

-- World of a pod: its WorldId attribute, else the layout table (pods 1..5 = W1, 6..7 = W2).
local function podWorld(inst: Instance, podIndex: number): number?
	local attrWorld = MapLayout.getWorldIdOf(inst)
	if attrWorld ~= nil then
		return attrWorld
	end
	for worldId, world in MapLayout.WORLDS do
		if world.pods[podIndex] ~= nil then
			return worldId
		end
	end
	return nil
end

-- Pod the player stands in now (highest PodIndex wins if boxes overlap), 0 = none. Presence only:
-- IdleService checks ownership (PodsMask) before paying MP/s.
local function findPod(player: Player): number
	local pos = ZoneService.getCharacterPosition(player)
	if pos == nil then
		return 0
	end
	local worldId = ZoneService.getWorld(player)
	local best = 0
	for inst in podParts do
		local index = MapLayout.getPodIndexOf(inst)
		if
			index ~= nil
			and index > best
			and index == math.floor(index)
			and index <= MAX_POD_INDEX
			and podWorld(inst, index) == worldId
			and MapLayout.isInsideBox(inst, pos, POD_PAD)
		then
			best = index
		end
	end
	return best
end

local function setPod(player: Player, podIndex: number)
	if podOf[player] == nil or podOf[player] == podIndex then
		return
	end
	podOf[player] = podIndex
	player:SetAttribute(PlayerAttr.CurrentPod, podIndex)
	podChangedEvent:Fire(player, podIndex)
end

local function updatePods()
	for _, player in Players:GetPlayers() do
		setPod(player, findPod(player))
	end
end

-- Portal sign (lean v1, D-034) --------------------------------------------------------------------

local function playerFromHit(hit: BasePart): Player?
	local model = hit:FindFirstAncestorOfClass("Model")
	while model ~= nil do
		local player = Players:GetPlayerFromCharacter(model)
		if player then
			return player
		end
		model = model:FindFirstAncestorOfClass("Model")
	end
	return nil
end

local function onPortalTouched(portal: Instance, hit: BasePart)
	local player = playerFromHit(hit)
	if player == nil then
		return
	end
	local target = MapLayout.getPortalTarget(portal)
	if target == nil or not MapLayout.isValidWorld(target) or target == ZoneService.getWorld(player) then
		return
	end
	-- Touched comes from the client that owns the character's physics, so confirm the position.
	local pos = ZoneService.getCharacterPosition(player)
	if pos == nil or not MapLayout.isInsideBox(portal, pos, PORTAL_PAD) then
		return
	end
	local now = os.clock()
	local last = lastPortalNotice[player]
	if last ~= nil and now - last < PORTAL_NOTICE_COOLDOWN then
		return
	end
	lastPortalNotice[player] = now
	-- Never teleports in v1. World travel (unlock check + teleportToWorld) is T-092 (Update 1).
	if notifyRemote then
		local payload: Types.NotifyPayload = { kind = "Info", text = PORTAL_NOTICE_TEXT, durationSec = 3 }
		notifyRemote:FireClient(player, payload)
	end
end

local function onPortalAdded(portal: Instance)
	if portalConns[portal] then
		return
	end
	local parts: { BasePart } = {}
	if portal:IsA("BasePart") then
		table.insert(parts, portal)
	end
	for _, d in portal:GetDescendants() do
		if d:IsA("BasePart") then
			table.insert(parts, d)
		end
	end
	if #parts == 0 then
		warn(`[ZoneService] Portal "{portal:GetFullName()}" has no part to touch`)
	end
	local conns = {}
	for _, part in parts do
		table.insert(
			conns,
			part.Touched:Connect(function(hit: BasePart)
				onPortalTouched(portal, hit)
			end)
		)
	end
	portalConns[portal] = conns
end

local function onPortalRemoved(portal: Instance)
	local conns = portalConns[portal]
	if conns then
		for _, conn in conns do
			conn:Disconnect()
		end
		portalConns[portal] = nil
	end
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
	local okRemote, remote = pcall(Remotes.getEvent, "Notify")
	notifyRemote = if okRemote then remote :: RemoteEvent else nil
	if notifyRemote == nil then
		warn("[ZoneService] Notify remote missing; the portal sign shows nothing")
	end
	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)
	for _, player in Players:GetPlayers() do
		task.spawn(onPlayerAdded, player)
	end
	MapLayout.observe("Pod", function(inst)
		podParts[inst] = true
	end, function(inst)
		podParts[inst] = nil
	end)
	MapLayout.observe("Portal", onPortalAdded, onPortalRemoved)
	local elapsed = 0
	RunService.Heartbeat:Connect(function(dt: number)
		elapsed += dt
		if elapsed < POD_CHECK_INTERVAL then
			return
		end
		elapsed = 0
		updatePods()
	end)
end

function ZoneService.getWorld(player: Player): Types.WorldId
	return worldOf[player] or 1
end

-- Pod (PodIndex) the player stands in, 0 = none. Server zone check every 0.5 s. Presence only:
-- callers check ownership themselves.
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

-- True when the player is alive, in the egg's world, and within INTERACT_RANGE (+ slack) of its
-- stand. Safe with untrusted input. A missing stand falls back to the layout (warned once).
function ZoneService.isNearEggStand(player: Player, eggId: Types.EggId): boolean
	if typeof(player) ~= "Instance" or not player:IsA("Player") then
		return false
	end
	if typeof(eggId) ~= "string" or #eggId == 0 or #eggId > MAX_EGG_ID_LEN then
		return false
	end
	local eggWorld = MapLayout.getEggWorld(eggId)
	if eggWorld == nil or eggWorld ~= ZoneService.getWorld(player) then
		return false
	end
	local stand = MapLayout.getEggStand(eggId)
	if stand == nil then
		warnMissingOnce("EggStand", eggId)
	else
		local standWorld = MapLayout.getWorldIdOf(stand)
		if standWorld ~= nil and standWorld ~= eggWorld then
			warnMissingOnce(`EggStand in WorldId {eggWorld}`, eggId)
			return false
		end
	end
	local standPos = MapLayout.getEggStandPosition(eggId)
	local playerPos = ZoneService.getCharacterPosition(player)
	if standPos == nil or playerPos == nil then
		return false
	end
	return (playerPos - standPos).Magnitude <= interactRange + RANGE_SLACK
end

return ZoneService
