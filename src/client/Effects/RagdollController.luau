--!strict
-- RagdollController (architecture 1d #35, T-066). Owned by physics-programmer. Client-only and cosmetic.
-- Duel knockback: when the server names the LOCAL user as the loser (`PlayEffect DuelKnockback {userId}`), this
-- client ragdolls its own character for EffectsConfig.Ragdoll.duration (2.5 s) on a cartoon arc into the ring's
-- foam pit, then always stands it back up. Also: the draw bounce (`PlayEffect DuelBounce`) and the winner pose
-- banner (`DuelState` Result). It never sends a remote and never decides anything: the server picks the
-- winner, the loser, the score and the rewards (architecture 4c); this module only draws what it is told.
--
-- Network ownership (decision D-065):
-- - Nothing here calls SetNetworkOwner (server-only API) and nothing asks the server to change ownership.
-- - The only physics this module touches is the LOCAL player's own character, which Roblox already gives to
--   that player's client by default. Its velocity/joint changes replicate the way normal walking does.
-- - It never touches another player's character, the ring, the pit or any map part. Other players' knockbacks
--   only get a pooled foam splash, drawn locally.
-- - Joints (Attachments + BallSocketConstraints) are created by this client in its own character, so they do
--   not replicate; Motor6D.Enabled / CanCollide changes are local too. No server state reads them.
-- - Exploit view: an exploiter can already fling their own character, so ragdoll code adds no new power; the
--   server must never read character position or physics to decide a duel (it does not: 4c), and this code
--   clamps every launch (EffectsConfig.clampLaunch) so a bad payload can never fling the local player.
-- Guards: ragdoll only for the local user, only in a duel (InDuel, or a DuelState Result in the last few
-- seconds), only with the root inside a Mog Ring box, at most once per cooldown, and a timed recovery that
-- also runs on errors, rematch countdowns, death and respawn.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local EffectPool = require(script.Parent.Util.EffectPool)
local EffectsConfig = require(ReplicatedStorage.Shared.Physics.EffectsConfig)
local MapLayout = require(ReplicatedStorage.Shared.World.MapLayout)
local Remotes = require(ReplicatedStorage.Shared.Contracts.Remotes)
local Types = require(ReplicatedStorage.Shared.Contracts.Types)

local RagdollController = {}

local cfg = EffectsConfig.Ragdoll
local localPlayer = Players.LocalPlayer

type Rig = {
	character: Model,
	motors: { Motor6D },
	sockets: { BallSocketConstraint },
	limbs: { BasePart },
	limbCollide: { [BasePart]: boolean },
}

local rig: Rig? -- joints for the current character, built on its first ragdoll and reused
local ragdolled = false
local ragdollToken = 0 -- bumped on every start/recover so a stale timer never recovers a newer ragdoll
local lastRagdollAt = -math.huge
local lastResultAt = -math.huge

local folder: Folder
local splashPool: EffectPool.Pool
local bouncePool: EffectPool.Pool
local winPool: EffectPool.Pool
local bannerGui: ScreenGui
local bannerTitle: TextLabel
local bannerSub: TextLabel
local bannerScale: UIScale
local bannerToken = 0

-- Helpers ------------------------------------------------------------------------------------------

local function rootOf(character: Model?): BasePart?
	local root = character and character:FindFirstChild("HumanoidRootPart")
	return if root and root:IsA("BasePart") then root else nil
end

local function humanoidOf(character: Model?): Humanoid?
	return if character then character:FindFirstChildOfClass("Humanoid") else nil
end

local function characterOf(userId: unknown): Model?
	if type(userId) ~= "number" then
		return nil
	end
	local player = Players:GetPlayerByUserId(userId)
	return if player then player.Character else nil
end

local function inRange(position: Vector3): boolean
	local camera = Workspace.CurrentCamera
	return camera ~= nil
		and (camera.CFrame.Position - position).Magnitude <= EffectsConfig.MAX_EFFECT_DISTANCE
end

-- The Mog Ring whose box (plus ringPad) holds `position`, from MapLayout only. nil outside every ring.
local function ringContaining(position: Vector3): MapLayout.RingParts?
	for worldId, world in MapLayout.WORLDS do
		for ringIndex = 1, #world.rings do
			local ring = MapLayout.getRing(worldId, ringIndex)
			if ring and MapLayout.isInsideBox(ring.model, position, cfg.ringPad) then
				return ring
			end
		end
	end
	return nil
end

local function pitTarget(ring: MapLayout.RingParts): Vector3?
	local pit = ring.pit
	if pit == nil then
		return nil -- not streamed in (or missing): caller uses the payload direction
	end
	return pit.Position + Vector3.new(0, pit.Size.Y / 2 + cfg.pitAimHeight, 0)
end

local function splashLater(position: Vector3)
	task.delay(cfg.flightTime, function()
		if inRange(position) then
			EffectPool.emit(splashPool, position, cfg.splashParticles)
		end
	end)
end

-- Rig (local character only) -----------------------------------------------------------------------

-- One BallSocket per Motor6D, except the root joint (keeps the root welded to the torso, so the camera and
-- the replicated root follow the body) and the neck (stays stiff: no floppy-head imagery, and the Humanoid
-- never sees a missing neck). Built once per character; ~13 instances on R15, 4 on R6.
local function buildRig(character: Model): Rig
	local motors: { Motor6D } = {}
	local sockets: { BallSocketConstraint } = {}
	for _, d in character:GetDescendants() do
		if not d:IsA("Motor6D") then
			continue
		end
		local p0, p1 = d.Part0, d.Part1
		if p0 == nil or p1 == nil or p0.Name == "HumanoidRootPart" or d.Name == "Neck" then
			continue
		end
		local a0 = Instance.new("Attachment")
		a0.Name = "RagdollA0"
		a0.CFrame = d.C0
		a0.Parent = p0
		local a1 = Instance.new("Attachment")
		a1.Name = "RagdollA1"
		a1.CFrame = d.C1
		a1.Parent = p1
		local socket = Instance.new("BallSocketConstraint")
		socket.Name = "RagdollSocket"
		socket.Attachment0 = a0
		socket.Attachment1 = a1
		socket.LimitsEnabled = true
		socket.UpperAngle = cfg.jointAngle
		socket.TwistLimitsEnabled = true
		socket.TwistLowerAngle = -cfg.twistAngle
		socket.TwistUpperAngle = cfg.twistAngle
		socket.Enabled = false
		socket.Parent = p1
		table.insert(motors, d)
		table.insert(sockets, socket)
	end
	local limbs: { BasePart } = {}
	local limbCollide: { [BasePart]: boolean } = {}
	for _, child in character:GetChildren() do
		if child:IsA("BasePart") and child.Name ~= "HumanoidRootPart" then
			table.insert(limbs, child)
			limbCollide[child] = child.CanCollide
		end
	end
	return {
		character = character,
		motors = motors,
		sockets = sockets,
		limbs = limbs,
		limbCollide = limbCollide,
	}
end

local function rigFor(character: Model): Rig
	local current = rig
	if current and current.character == character then
		return current
	end
	local built = buildRig(character)
	rig = built
	return built
end

local function setJoints(r: Rig, ragdoll: boolean)
	-- Sockets first when going limp, motors first when standing up, so limbs are never unjointed.
	if ragdoll then
		for _, socket in r.sockets do
			socket.Enabled = true
		end
		for _, motor in r.motors do
			motor.Enabled = false
		end
	else
		for _, motor in r.motors do
			motor.Enabled = true
		end
		for _, socket in r.sockets do
			socket.Enabled = false
		end
	end
	for _, limb in r.limbs do
		-- TODO(verify-api): confirm in Studio (T-089) that the Humanoid leaves limb CanCollide alone while in
		-- HumanoidStateType.Physics, so limbs rest on the foam instead of sinking through it.
		limb.CanCollide = if ragdoll then true else (r.limbCollide[limb] == true)
	end
end

local function recover(token: number)
	if token ~= ragdollToken or not ragdolled then
		return
	end
	ragdolled = false
	ragdollToken += 1
	local r = rig
	if r == nil or r.character.Parent == nil then
		return
	end
	setJoints(r, false)
	local humanoid = humanoidOf(r.character)
	if humanoid and humanoid.Health > 0 then
		humanoid:ChangeState(Enum.HumanoidStateType.GettingUp)
	end
end

local function recoverNow()
	if ragdolled then
		recover(ragdollToken)
	end
end

local function startRagdoll(character: Model, root: BasePart, launch: Vector3)
	local humanoid = humanoidOf(character)
	if humanoid == nil or humanoid.Health <= 0 or root.Anchored then
		return
	end
	ragdolled = true
	ragdollToken += 1
	local token = ragdollToken
	-- The recovery is scheduled before anything can fail, so the player always stands up.
	task.delay(cfg.duration, recover, token)

	local ok, err = pcall(function()
		local r = rigFor(character)
		-- TODO(verify-api): confirm in Studio (T-089) that a client ChangeState(Physics) on its own character
		-- stays in Physics until we change it, and that other clients see the limbs flop (only the owner
		-- disables the Motor6Ds; the root/torso arc replicates either way).
		humanoid:ChangeState(Enum.HumanoidStateType.Physics)
		setJoints(r, true)
		for _, limb in r.limbs do
			limb.AssemblyLinearVelocity = launch
		end
		root.AssemblyLinearVelocity = launch
		-- Cartoon forward flip: spin around the sideways axis of the flight.
		local flat = Vector3.new(launch.X, 0, launch.Z)
		-- up x flight direction = (z, 0, -x) for a flat unit vector.
		local unit = if flat.Magnitude > 1e-3 then flat.Unit else Vector3.zAxis
		local axis = Vector3.new(unit.Z, 0, -unit.X)
		local torso = character:FindFirstChild("UpperTorso") or character:FindFirstChild("Torso")
		if torso and torso:IsA("BasePart") then
			torso.AssemblyAngularVelocity = axis * cfg.spinSpeed
		end
	end)
	if not ok then
		warn(`[RagdollController] ragdoll failed, standing up: {err}`)
		recover(token)
	end
end

-- PlayEffect handlers -------------------------------------------------------------------------------

local function onKnockback(p: { [string]: unknown })
	local character = characterOf(p.userId)
	local root = rootOf(character)
	if character == nil or root == nil then
		return
	end
	local ring = ringContaining(root.Position)
	if ring == nil then
		return -- never outside a ring (GDD 6)
	end
	local target = pitTarget(ring)

	if p.userId ~= localPlayer.UserId then
		-- Someone else's knockback: their own client ragdolls them; we only splash the foam.
		splashLater(target or root.Position)
		return
	end

	local now = os.clock()
	if ragdolled or now - lastRagdollAt < cfg.cooldown then
		return
	end
	local inDuel = localPlayer:GetAttribute(Types.PlayerAttr.InDuel) == true
	if not inDuel and now - lastResultAt > cfg.resultWindow then
		return
	end
	local launch = if target
		then EffectsConfig.launchVelocity(root.Position, target, Workspace.Gravity)
		else EffectsConfig.fallbackLaunch(EffectsConfig.flatDirection(p.direction))
	lastRagdollAt = now
	startRagdoll(character, root, launch)
	splashLater(target or root.Position + Vector3.new(launch.X, 0, launch.Z) * cfg.flightTime)
end

local function onBounce(p: { [string]: unknown })
	local root = rootOf(characterOf(p.userId))
	if root == nil or ringContaining(root.Position) == nil then
		return
	end
	local spot = root.Position + Vector3.new(0, cfg.bounceHeight, 0)
	if inRange(spot) then
		EffectPool.emit(bouncePool, spot, cfg.bounceParticles)
	end
	if p.userId == localPlayer.UserId and not ragdolled and not root.Anchored then
		-- TODO(verify-api): tune in Studio (T-089) that the Humanoid keeps this hop with JumpPower 0 (duel lock).
		local v = root.AssemblyLinearVelocity
		root.AssemblyLinearVelocity = Vector3.new(v.X, math.max(v.Y, 0) + cfg.bounceUpSpeed, v.Z)
	end
end

local function onPlayEffect(effect: unknown, payload: unknown)
	if effect ~= "DuelKnockback" and effect ~= "DuelBounce" then
		return
	end
	local p = if type(payload) == "table" then payload :: { [string]: unknown } else {}
	if effect == "DuelKnockback" then
		onKnockback(p)
	else
		onBounce(p)
	end
end

-- Winner pose banner --------------------------------------------------------------------------------

local function showBanner(title: string, sub: string)
	bannerToken += 1
	local token = bannerToken
	bannerTitle.Text = title
	bannerSub.Text = sub
	bannerSub.Visible = sub ~= ""
	bannerScale.Scale = 0.6
	bannerGui.Enabled = true
	TweenService:Create(
		bannerScale,
		TweenInfo.new(cfg.bannerPopTime, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
		{ Scale = 1 }
	):Play()
	task.delay(cfg.bannerTime, function()
		if token == bannerToken then
			bannerGui.Enabled = false
		end
	end)
end

local function onDuelState(payload: unknown)
	if type(payload) ~= "table" then
		return
	end
	local p = payload :: { [string]: unknown }
	if p.phase == "Result" then
		lastResultAt = os.clock()
		if p.result == "Win" then
			showBanner(cfg.winText, cfg.winSubText)
			local root = rootOf(localPlayer.Character)
			if root then
				EffectPool.emit(winPool, root.Position + Vector3.new(0, cfg.winHeight, 0), cfg.winParticles)
			end
		elseif p.result == "Draw" then
			showBanner(cfg.drawText, "")
		end
	elseif p.phase == "Countdown" or p.phase == "Ended" then
		recoverNow() -- rematch or duel over: never start a phase lying down
	end
end

local function makeLabel(name: string, size: UDim2, position: UDim2, maxText: number): TextLabel
	local label = Instance.new("TextLabel")
	label.Name = name
	label.AnchorPoint = Vector2.new(0.5, 0.5)
	label.Size = size
	label.Position = position
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.FredokaOne
	label.TextScaled = true
	label.TextColor3 = Color3.new(1, 1, 1)
	label.TextStrokeTransparency = 0.2
	local limit = Instance.new("UITextSizeConstraint")
	limit.MaxTextSize = maxText
	limit.Parent = label
	return label
end

local function buildBanner()
	bannerGui = Instance.new("ScreenGui")
	bannerGui.Name = "DuelBanner"
	bannerGui.ResetOnSpawn = false
	bannerGui.IgnoreGuiInset = true
	bannerGui.DisplayOrder = 42 -- above the rank-up (40), below the hatch reveal (45)
	bannerGui.Enabled = false

	local holder = Instance.new("Frame")
	holder.Name = "Holder"
	holder.AnchorPoint = Vector2.new(0.5, 0.5)
	holder.Position = UDim2.fromScale(0.5, 0.2)
	holder.Size = UDim2.fromScale(0.8, 0.18)
	holder.BackgroundTransparency = 1
	bannerScale = Instance.new("UIScale")
	bannerScale.Parent = holder
	holder.Parent = bannerGui

	bannerTitle = makeLabel("Title", UDim2.fromScale(1, 0.6), UDim2.fromScale(0.5, 0.3), 72)
	bannerTitle.TextColor3 = cfg.bannerColor
	bannerTitle.Parent = holder
	bannerSub = makeLabel("Sub", UDim2.fromScale(1, 0.35), UDim2.fromScale(0.5, 0.8), 36)
	bannerSub.Parent = holder
end

-- Lifecycle ----------------------------------------------------------------------------------------

local function onCharacterAdded(character: Model)
	-- New character: old joints died with the old one; drop any ragdoll state so the next one rebuilds.
	ragdolled = false
	ragdollToken += 1
	rig = nil
	local humanoid = character:WaitForChild("Humanoid", 10)
	if humanoid and humanoid:IsA("Humanoid") then
		humanoid.Died:Connect(function()
			ragdolled = false
			ragdollToken += 1
		end)
	end
end

function RagdollController:Init()
	folder = Instance.new("Folder")
	folder.Name = "DuelEffects"
	local pools = EffectsConfig.Pools
	splashPool = EffectPool.new("FoamSplash", pools.FoamSplash.size, pools.FoamSplash.look, folder)
	bouncePool = EffectPool.new("DuelBounce", pools.DuelBounce.size, pools.DuelBounce.look, folder)
	winPool = EffectPool.new("DuelWin", pools.DuelWin.size, pools.DuelWin.look, folder)
	folder.Parent = Workspace
	buildBanner()
end

function RagdollController:Start()
	-- WaitForChild calls yield, so they run here, never in Init.
	bannerGui.Parent = localPlayer:WaitForChild("PlayerGui")
	Remotes.getEvent("PlayEffect").OnClientEvent:Connect(onPlayEffect)
	Remotes.getEvent("DuelState").OnClientEvent:Connect(onDuelState)
	localPlayer.CharacterAdded:Connect(onCharacterAdded)
	if localPlayer.Character then
		task.spawn(onCharacterAdded, localPlayer.Character)
	end
end

return RagdollController
