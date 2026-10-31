--!strict
-- PetFollowController (architecture 1d #36, T-044). Owned by physics-programmer. Client-only and cosmetic.
-- Renders the equipped pets of every player within Pets.renderRadius studs (the local player first, then
-- nearest), read from the `EquippedPets` attribute PetService writes. Pets float in rows behind their owner with
-- a small bob (GDD 5: simple float, no pathfinding).
-- Budget (architecture 7): at most Pets.maxModels pet models alive (shown + cached), one Heartbeat connection that
-- moves every pet with one `Workspace:BulkMoveTo` call, no per-pet connections, no collisions/touch/query.
-- Models: clones of `ReplicatedStorage.Assets.Pets.<petId>` (builder, T-042). Until a model exists (or if it is
-- not a Model/BasePart) the pet is a plain ball in its rarity color, so this works with no art at all.
-- Network ownership: none involved. Pets are client-created, anchored (root) or welded to it, and never
-- replicate; they never decide anything.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local EconomyConfig = require(ReplicatedStorage.Shared.Gameplay.EconomyConfig)
local EffectsConfig = require(ReplicatedStorage.Shared.Physics.EffectsConfig)
local Types = require(ReplicatedStorage.Shared.Contracts.Types)

local PetFollowController = {}

local CFG = EffectsConfig.Pets
local HIDDEN = CFrame.new(0, -10000, 0)

type Visual = {
	petId: string,
	instance: Instance, -- the Model or the fallback ball
	root: BasePart, -- anchored; every other part is welded to it
	key: string?, -- "<userId>:<slot>" while shown, nil while cached
	owner: BasePart?, -- owner's HumanoidRootPart while shown
	slot: number,
	count: number, -- pets in the owner's formation
	current: CFrame,
}

type Parsed = { raw: unknown, ids: { string } }

local localPlayer = Players.LocalPlayer
local folder: Folder
local visuals: { Visual } = {} -- every pet visual alive, shown or cached (<= CFG.maxModels)
local shownByKey: { [string]: Visual } = {}
local parsedByUser: { [number]: Parsed } = {}
local sinceRefresh = math.huge
local moveParts: { BasePart } = {}
local moveCFrames: { CFrame } = {}

local function rootOf(player: Player): BasePart?
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return root
	end
	return nil
end

local function rarityColor(petId: string): Color3
	local pet = EconomyConfig.PETS[petId]
	local color = pet and EffectsConfig.RarityColors[pet.rarity]
	return color or EffectsConfig.DEFAULT_RARITY_COLOR
end

local function quiet(part: BasePart)
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false
	part.CastShadow = false
	part.Massless = true
	part.Locked = true
end

local function buildBall(petId: string): (Instance, BasePart)
	local ball = Instance.new("Part")
	ball.Name = `Pet_{petId}`
	ball.Shape = Enum.PartType.Ball
	ball.Size = Vector3.one * CFG.sphereSize
	ball.Material = Enum.Material.SmoothPlastic
	ball.Color = rarityColor(petId)
	ball.Anchored = true
	quiet(ball)
	return ball, ball
end

-- Clones the builder's template when there is a usable one; otherwise a ball. Never yields.
local function buildVisual(petId: string): Visual
	local instance: Instance, root: BasePart
	local assets = ReplicatedStorage:FindFirstChild("Assets")
	local petsFolder = assets and assets:FindFirstChild("Pets")
	local template = petsFolder and petsFolder:FindFirstChild(petId)
	local clone: Instance? = nil
	if template and (template:IsA("Model") or template:IsA("BasePart")) then
		clone = template:Clone()
	end
	local cloneRoot: BasePart? = nil
	if clone then
		for _, d in clone:GetDescendants() do
			if d:IsA("BaseScript") then
				d:Destroy() -- templates are visuals only
			end
		end
		if clone:IsA("BasePart") then
			cloneRoot = clone
		elseif clone:IsA("Model") then
			local found = clone.PrimaryPart or clone:FindFirstChildWhichIsA("BasePart", true)
			if found and found:IsA("BasePart") then
				cloneRoot = found
			end
		end
	end
	if clone and cloneRoot then
		instance, root = clone, cloneRoot
		root.Anchored = true
		quiet(root)
		for _, d in clone:GetDescendants() do
			if d:IsA("BasePart") and d ~= root then
				quiet(d)
				d.Anchored = false
				local weld = Instance.new("WeldConstraint")
				weld.Part0 = root
				weld.Part1 = d
				weld.Parent = d
			end
		end
	else
		if clone then
			clone:Destroy()
		end
		instance, root = buildBall(petId)
	end
	root.CFrame = HIDDEN
	return {
		petId = petId,
		instance = instance,
		root = root,
		key = nil,
		owner = nil,
		slot = 1,
		count = 1,
		current = HIDDEN,
	}
end

local function idsFor(player: Player): { string }
	local raw = player:GetAttribute(Types.PlayerAttr.EquippedPets)
	local cached = parsedByUser[player.UserId]
	if cached and cached.raw == raw then
		return cached.ids
	end
	local ids = EffectsConfig.parseEquippedPets(raw)
	parsedByUser[player.UserId] = { raw = raw, ids = ids }
	return ids
end

type Want = { key: string, petId: string, owner: BasePart, slot: number, count: number }

-- Which pets should be visible: local player first, then by distance, capped at CFG.maxModels.
local function collectWants(): { Want }
	local center: Vector3? = nil
	local localRoot = rootOf(localPlayer)
	if localRoot then
		center = localRoot.Position
	elseif Workspace.CurrentCamera then
		center = Workspace.CurrentCamera.CFrame.Position
	end
	local wants: { Want } = {}
	if not center then
		return wants
	end
	type Candidate = { player: Player, root: BasePart, dist: number }
	local candidates: { Candidate } = {}
	for _, player in Players:GetPlayers() do
		local root = rootOf(player)
		if root then
			local dist = if player == localPlayer then -1 else (root.Position - center).Magnitude
			if dist <= CFG.renderRadius then
				table.insert(candidates, { player = player, root = root, dist = dist })
			end
		end
	end
	table.sort(candidates, function(a: Candidate, b: Candidate)
		return a.dist < b.dist
	end)
	for _, c in candidates do
		local ids = idsFor(c.player)
		for slot, petId in ids do
			if #wants >= CFG.maxModels then
				return wants
			end
			table.insert(wants, {
				key = `{c.player.UserId}:{slot}`,
				petId = petId,
				owner = c.root,
				slot = slot,
				count = #ids,
			})
		end
	end
	return wants
end

local function hide(v: Visual)
	v.key = nil
	v.owner = nil
	v.instance.Parent = nil
end

local function show(v: Visual, want: Want)
	if v.key ~= want.key then
		v.current = HIDDEN -- new owner or slot: snap to the target on the next frame instead of gliding over
	end
	v.key = want.key
	v.owner = want.owner
	v.slot = want.slot
	v.count = want.count
	shownByKey[want.key] = v
	if v.instance.Parent ~= folder then
		v.instance.Parent = folder
	end
end

local function refresh()
	local wants = collectWants()
	local wanted: { [string]: Want } = {}
	for _, w in wants do
		wanted[w.key] = w
	end

	-- Keep pets that still match; free everything else.
	local nextShown: { [string]: Visual } = {}
	local free: { Visual } = {}
	for _, v in visuals do
		local w = if v.key then wanted[v.key] else nil
		if w and w.petId == v.petId then
			nextShown[w.key] = v
		else
			table.insert(free, v)
		end
	end
	shownByKey = nextShown

	for _, w in wants do
		local existing = shownByKey[w.key]
		if existing then
			show(existing, w) -- owner root or formation size may have changed
			continue
		end
		-- 1) a cached visual of the same pet, 2) a new one under the cap, 3) rebuild a free one.
		local pick: Visual? = nil
		for i, v in free do
			if v.petId == w.petId then
				pick = table.remove(free, i)
				break
			end
		end
		if not pick and #visuals < CFG.maxModels then
			pick = buildVisual(w.petId)
			table.insert(visuals, pick)
		end
		if not pick then
			local old = table.remove(free)
			if old then
				local index = table.find(visuals, old)
				old.instance:Destroy()
				pick = buildVisual(w.petId)
				if index then
					visuals[index] = pick
				end
			end
		end
		if pick then
			show(pick, w)
		end
	end

	for _, v in free do
		hide(v) -- not picked above: cached until a pet with the same id is wanted again
	end

	-- Forget parsed attributes of players who left.
	for userId in parsedByUser do
		if not Players:GetPlayerByUserId(userId) then
			parsedByUser[userId] = nil
		end
	end
end

local function onHeartbeat(dt: number)
	sinceRefresh += dt
	if sinceRefresh >= CFG.refreshInterval then
		sinceRefresh = 0
		refresh()
	end

	local now = os.clock()
	local alpha = EffectsConfig.followAlpha(dt)
	table.clear(moveParts)
	table.clear(moveCFrames)
	for _, v in shownByKey do
		local owner = v.owner
		if not owner or owner.Parent == nil then
			continue -- owner respawning: the pet waits; the next refresh re-targets or hides it
		end
		local look = owner.CFrame.LookVector
		local yaw = math.atan2(-look.X, -look.Z)
		local offset = EffectsConfig.petOffset(v.slot, v.count)
			+ Vector3.new(0, math.sin(now * CFG.bobSpeed + v.slot) * CFG.bobAmplitude, 0)
		local target = CFrame.new(owner.Position) * CFrame.Angles(0, yaw, 0) * CFrame.new(offset)
		local cf = if (v.current.Position - target.Position).Magnitude > CFG.snapDistance
			then target
			else v.current:Lerp(target, alpha)
		v.current = cf
		table.insert(moveParts, v.root)
		table.insert(moveCFrames, cf)
	end
	if #moveParts > 0 then
		-- TODO(verify-api): confirm in Studio that BulkMoveTo on an anchored root carries its WeldConstraint-ed
		-- parts (multi-part pet models from T-042); fallback balls are single parts and unaffected.
		Workspace:BulkMoveTo(moveParts, moveCFrames, Enum.BulkMoveMode.FireCFrameChanged)
	end
end

function PetFollowController:Init()
	folder = Instance.new("Folder")
	folder.Name = "ClientPets"
	folder.Parent = Workspace
end

function PetFollowController:Start()
	RunService.Heartbeat:Connect(onHeartbeat)
end

return PetFollowController
