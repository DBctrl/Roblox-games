--!strict
-- CharacterService (T-017 basic). Owned by world-programmer. Server only.
-- The ONLY writer of Humanoid WalkSpeed / JumpPower (architecture 1e). Other services ask through
-- setSpeedMultiplier (Speed Sneakers) and reason-keyed setMovementLocked (duels, cinematics).
-- State is kept per player, not per character, and re-applied on every respawn.
-- T-038: rank looks and fits. Clones cartoon Accessory templates from ServerStorage.Assets.Looks
-- (names in Shared.World.MapLayout) onto the avatar, at most 6, never edits the body, and wears
-- nothing when the player turns the ShowOwnLook setting off. Nil-safe: missing art = no accessory.
-- T-059: duel movement lock. ZoneService holds the "DuelRing" lock from teleportToRing until the
-- ring is released (or a duelist leaves); DuelService may add its own "Duel" lock. Locks are
-- reason-keyed, survive respawn, and a new lock stops walking momentum at once. WalkSpeed 0 alone
-- can be bypassed by an exploiting client, so ZoneService also leashes ring occupants on the server.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local MapLayout = require(Shared:WaitForChild("World"):WaitForChild("MapLayout"))
local Types = require(Shared:WaitForChild("Contracts"):WaitForChild("Types"))

local PlayerAttr = Types.PlayerAttr

local LOOK_MARK_ATTR = "AuraUpLook" -- set on every accessory this service adds (so only ours are removed)
local APPEARANCE_WAIT_SEC = 8
local STARTER_FIT = "StarterFit"
-- Attributes whose change can add or remove a fit (or hide the look).
local LOOK_TRIGGER_ATTRS = {
	PlayerAttr.SettingShowOwnLook,
	PlayerAttr.FirstWin,
	PlayerAttr.Vip,
	PlayerAttr.StarterPackOwned,
}

type DataServiceLike = { getData: (player: Player) -> Types.ProfileData? }

local BASE_WALK_SPEED = 16 -- Roblox default
local BASE_JUMP_POWER = 50 -- Roblox default
local MIN_SPEED_MULT = 0.25
local MAX_SPEED_MULT = 3
local MAX_REASON_LEN = 32
local HUMANOID_WAIT_SEC = 5

type PlayerState = {
	speedMult: number,
	locks: { [string]: true },
	lookId: string?,
}

local CharacterService = {}

local states: { [Player]: PlayerState } = {}

local function stateOf(player: Player): PlayerState?
	if player.Parent ~= Players then
		return nil
	end
	local state = states[player]
	if state == nil then
		state = { speedMult = 1, locks = {}, lookId = nil }
		states[player] = state
	end
	return state
end

local function isLocked(state: PlayerState): boolean
	return next(state.locks) ~= nil
end

local function humanoidOf(player: Player): Humanoid?
	local character = player.Character
	return if character then character:FindFirstChildOfClass("Humanoid") else nil
end

local function apply(player: Player)
	local state = states[player]
	local humanoid = humanoidOf(player)
	if state == nil or humanoid == nil then
		return
	end
	humanoid.UseJumpPower = true
	if isLocked(state) then
		humanoid.WalkSpeed = 0
		humanoid.JumpPower = 0
	else
		humanoid.WalkSpeed = BASE_WALK_SPEED * state.speedMult
		humanoid.JumpPower = BASE_JUMP_POWER
	end
end

-- On a new lock: drop the walking momentum (horizontal velocity) so the player stops at once
-- instead of sliding. Gravity and later physics (the duel knockback) are left alone.
local function stopWalking(player: Player)
	local humanoid = humanoidOf(player)
	local root = humanoid and humanoid.RootPart
	if root == nil then
		return
	end
	local v = root.AssemblyLinearVelocity
	root.AssemblyLinearVelocity = Vector3.new(0, math.min(v.Y, 0), 0)
end

-- Looks and fits ----------------------------------------------------------------------------------

local dataService: DataServiceLike? = nil
local warnedTemplates: { [string]: true } = {}

-- Finds a Data-folder service by name (World may require Data, architecture 1a). nil if absent.
local function findDataModule(name: string): any
	local serverRoot = script.Parent and script.Parent.Parent
	local dataFolder = serverRoot and serverRoot:FindFirstChild("Data")
	local module = dataFolder and dataFolder:FindFirstChild(name)
	if module and module:IsA("ModuleScript") then
		local ok, service = pcall(require :: any, module)
		if ok and typeof(service) == "table" then
			return service
		end
	end
	return nil
end

local function warnTemplateOnce(id: string, why: string)
	if warnedTemplates[id] then
		return
	end
	warnedTemplates[id] = true
	warn(`[CharacterService] Look template "{id}" {why}; skipping it until builder adds it`)
end

local function templateOf(id: string): Instance?
	local assets = ServerStorage:FindFirstChild(MapLayout.LOOK_ASSETS_FOLDER)
	local looks = assets and assets:FindFirstChild(MapLayout.LOOK_TEMPLATES_FOLDER)
	local template = looks and looks:FindFirstChild(id)
	if template == nil then
		warnTemplateOnce(
			id,
			`is missing from ServerStorage.{MapLayout.LOOK_ASSETS_FOLDER}.{MapLayout.LOOK_TEMPLATES_FOLDER}`
		)
	end
	return template
end

local function ownsFit(player: Player, fitId: string, data: Types.ProfileData?): boolean
	local ent = data and data.entitlements
	local cosmetics = ent and ent.cosmetics
	if cosmetics and cosmetics[fitId] == true then
		return true
	end
	if fitId == STARTER_FIT then
		return player:GetAttribute(PlayerAttr.FirstWin) == true or (data ~= nil and data.firstWin == true)
	elseif fitId == "RookieShades" then
		return player:GetAttribute(PlayerAttr.StarterPackOwned) == true
	elseif fitId == "VipSparkleAura" then
		return player:GetAttribute(PlayerAttr.Vip) == true or (ent ~= nil and ent.vip == true)
	end
	return false
end

-- Template ids to wear, in priority order: owned paid fits, then the rank look, then the free
-- Starter Fit. The 6-accessory cap cuts from the end, so a bought fit is never dropped.
local function wearList(player: Player, lookId: string?): { string }
	local data = if dataService then dataService.getData(player) else nil
	local list = {}
	for _, fitId in MapLayout.FIT_IDS do
		if fitId ~= STARTER_FIT and ownsFit(player, fitId, data) then
			table.insert(list, fitId)
		end
	end
	if lookId and table.find(MapLayout.LOOK_IDS, lookId) then
		table.insert(list, lookId)
	end
	if ownsFit(player, STARTER_FIT, data) then
		table.insert(list, STARTER_FIT)
	end
	return list
end

-- A clean copy of one template accessory: no scripts, no physics. nil if it is not a usable accessory.
local function cleanAccessory(source: Instance): Accessory?
	if not source:IsA("Accessory") then
		return nil
	end
	local handle = source:FindFirstChild("Handle")
	if handle == nil or not handle:IsA("BasePart") then
		return nil
	end
	local copy = (source :: Accessory):Clone()
	for _, d in copy:GetDescendants() do
		if d:IsA("LuaSourceContainer") then
			d:Destroy()
		elseif d:IsA("BasePart") then
			d.Anchored = false
			d.CanCollide = false
			d.CanTouch = false
			d.CanQuery = false
			d.Massless = true
		end
	end
	copy:SetAttribute(LOOK_MARK_ATTR, true)
	return copy
end

local function removeLook(character: Model)
	for _, child in character:GetChildren() do
		if child:IsA("Accessory") and child:GetAttribute(LOOK_MARK_ATTR) == true then
			child:Destroy()
		end
	end
end

local function applyLook(player: Player)
	local state = states[player]
	local character = player.Character
	local humanoid = humanoidOf(player)
	if state == nil or character == nil or humanoid == nil then
		return
	end
	removeLook(character)
	if player:GetAttribute(PlayerAttr.SettingShowOwnLook) == false then
		return -- the player turned "show my own avatar look" off (GDD 7)
	end
	local worn = 0
	for _, id in wearList(player, state.lookId) do
		local template = templateOf(id)
		if template then
			local skipped = false
			-- Only Accessory children count. Clothing, BodyColors, scales and meshes are ignored on
			-- purpose: looks never edit the body (GDD 7, 11).
			for _, child in template:GetChildren() do
				if worn >= MapLayout.MAX_LOOK_ACCESSORIES then
					return
				end
				local accessory = cleanAccessory(child)
				if accessory then
					humanoid:AddAccessory(accessory)
					worn += 1
				else
					skipped = true
				end
			end
			if skipped then
				warnTemplateOnce(id, "holds something that is not an Accessory with a Handle")
			end
		end
	end
end

local function onCharacterAdded(player: Player, character: Model)
	local humanoid = character:WaitForChild("Humanoid", HUMANOID_WAIT_SEC)
	if humanoid == nil or player.Character ~= character then
		return
	end
	apply(player)
	-- Wait for the avatar's own appearance first, so it does not replace our accessories.
	if not player:HasAppearanceLoaded() then
		local loaded = false
		local conn = player.CharacterAppearanceLoaded:Connect(function()
			loaded = true
		end)
		local deadline = os.clock() + APPEARANCE_WAIT_SEC
		while not loaded and os.clock() < deadline and player.Character == character do
			task.wait(0.2)
		end
		conn:Disconnect()
	end
	if player.Character == character and character:IsDescendantOf(workspace) then
		applyLook(player)
	end
end

local function onPlayerAdded(player: Player)
	if states[player] ~= nil then
		return -- already handled (joined between Connect and GetPlayers)
	end
	stateOf(player)
	for _, attr in LOOK_TRIGGER_ATTRS do
		player:GetAttributeChangedSignal(attr):Connect(function()
			applyLook(player)
		end)
	end
	player.CharacterAdded:Connect(function(character)
		onCharacterAdded(player, character)
	end)
	if player.Character then
		task.spawn(onCharacterAdded, player, player.Character)
	end
end

function CharacterService:Init() end

function CharacterService:Start()
	local data = findDataModule("DataService")
	if data and typeof(data.getData) == "function" then
		dataService = data :: DataServiceLike
	else
		warn("[CharacterService] DataService not found; only attribute-based fits are worn")
	end
	-- Exclusive fits bought later (sprint 3). Connect only when the module and signal exist.
	local monetization = findDataModule("MonetizationService")
	local changed = monetization and monetization.EntitlementsChanged
	if typeof(changed) == "RBXScriptSignal" then
		changed:Connect(function(player: Player)
			applyLook(player)
		end)
	end
	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(function(player)
		states[player] = nil
	end)
	for _, player in Players:GetPlayers() do
		task.spawn(onPlayerAdded, player)
	end
end

-- Walk speed = 16 x mult (clamped 0.25..3). 1 = normal; Speed Sneakers use 1.5. Never yields.
function CharacterService.setSpeedMultiplier(player: Player, mult: number)
	if typeof(mult) ~= "number" or mult ~= mult or math.abs(mult) == math.huge then
		return
	end
	local state = stateOf(player)
	if state == nil then
		return
	end
	local clamped = math.clamp(mult, MIN_SPEED_MULT, MAX_SPEED_MULT)
	if state.speedMult == clamped then
		return
	end
	state.speedMult = clamped
	apply(player)
end

function CharacterService.getSpeedMultiplier(player: Player): number
	local state = states[player]
	return if state then state.speedMult else 1
end

-- Freezes walking and jumping while any reason holds a lock ("Duel", "Cinematic", ...). Each reason
-- is independent: unlocking "Duel" keeps a "Cinematic" lock. Survives respawn. Never yields.
function CharacterService.setMovementLocked(player: Player, reason: string, locked: boolean)
	if
		typeof(reason) ~= "string"
		or #reason == 0
		or #reason > MAX_REASON_LEN
		or typeof(locked) ~= "boolean"
	then
		return
	end
	local state = stateOf(player)
	if state == nil then
		return
	end
	local wasLocked = isLocked(state)
	state.locks[reason] = if locked then true else nil
	if wasLocked ~= isLocked(state) then
		apply(player)
		if not wasLocked then
			stopWalking(player)
		end
	end
end

function CharacterService.isMovementLocked(player: Player): boolean
	local state = states[player]
	return state ~= nil and isLocked(state)
end

-- Sets the rank look (a MapLayout.LOOK_IDS name) and re-dresses the avatar with it plus owned fits:
-- cartoon accessories only, at most 6, none while ShowOwnLook is off. Kept across respawns.
-- Calling it again with the same id re-applies (use it after granting a fit). Never yields.
function CharacterService.setLook(player: Player, lookId: string)
	if typeof(lookId) ~= "string" or #lookId > 64 then
		return
	end
	if not table.find(MapLayout.LOOK_IDS, lookId) then
		warn(`[CharacterService] Unknown look id "{lookId}" (not in MapLayout.LOOK_IDS)`)
		return
	end
	local state = stateOf(player)
	if state then
		state.lookId = lookId
		applyLook(player)
	end
end

return CharacterService
