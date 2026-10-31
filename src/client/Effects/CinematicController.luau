--!strict
-- CinematicController (architecture 1d #37). Owned by physics-programmer. Client-only and cosmetic.
-- Rank-up moment (T-043, GDD 7): 3 s spotlight, confetti, camera orbit and a "look pops on" flash, from the
-- server's `PlayEffect RankUp {userId, rank}`. The new look itself is applied by the server (CharacterService);
-- this only frames it. Other players within RankUp.nearbyDistance of the camera see the spotlight, confetti and
-- pop on that character, with no camera change. The local orbit has a Skip button and always gives the camera
-- back (type, subject, field of view) when it ends, is skipped, or the character dies.
-- Hatch reveal (T-045, GDD 5): about 2 s egg wobble, flash and one card per pet from the server's `HatchResult`
-- (x3 hatch = 3 cards). Tap anywhere skips to the cards, a second tap closes. Never rolls on the client.
-- It never sends a remote and never reads or writes game state. One render-step function drives every moment
-- (no tweens, no per-moment connections). Rigs (beam, lamp, highlight) and confetti emitters are pooled and
-- built in Init.
-- Network ownership: none involved. All parts are client-created, anchored, non-colliding and never replicate.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local EconomyConfig = require(ReplicatedStorage.Shared.Gameplay.EconomyConfig)
local EffectPool = require(script.Parent.Util.EffectPool)
local EffectsConfig = require(ReplicatedStorage.Shared.Physics.EffectsConfig)
local Remotes = require(ReplicatedStorage.Shared.Contracts.Remotes)
local Types = require(ReplicatedStorage.Shared.Contracts.Types)

local CinematicController = {}

local RENDER_STEP_NAME = "AuraCinematic"
local HIDDEN_CFRAME = CFrame.new(0, -10000, 0)

type Rig = {
	beam: Part,
	lamp: Part,
	light: SpotLight,
	highlight: Highlight,
	busy: boolean,
}

type SavedCamera = {
	cameraType: Enum.CameraType,
	subject: Instance?,
	fov: number,
	offset: Vector3, -- camera position minus root position at start
	look: Vector3, -- camera look vector at start
	startAngle: number,
}

type Moment = {
	userId: number,
	rank: number,
	root: BasePart,
	character: Model,
	rig: Rig?,
	startedAt: number,
	nextBurst: number, -- index into RankUp.confettiBursts
	popped: boolean,
	camera: SavedCamera?, -- set only for the local player's orbit
}

local localPlayer = Players.LocalPlayer
local folder: Folder
local confettiPool: EffectPool.Pool
local rigs: { Rig } = {}
local moments: { [number]: Moment } = {} -- by userId
local momentCount = 0
local bound = false

-- Rank-up GUI (title + Skip), shown only during the local orbit.
local rankGui: ScreenGui
local rankTitle: TextLabel
local rankName: TextLabel
local skipButton: TextButton

local function newPart(name: string): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Locked = true
	part.Transparency = 1
	part.CFrame = HIDDEN_CFRAME
	return part
end

local function buildRig(i: number): Rig
	local cfg = EffectsConfig.RankUp
	local beam = newPart(`RankUpBeam_{i}`)
	beam.Shape = Enum.PartType.Cylinder -- axis is the part's X; rotated upright when placed
	beam.Size = Vector3.new(cfg.beamHeight, cfg.beamWidth, cfg.beamWidth)
	beam.Material = Enum.Material.Neon
	beam.Color = cfg.beamColor
	beam.Parent = folder

	local lamp = newPart(`RankUpLamp_{i}`)
	lamp.Size = Vector3.new(0.2, 0.2, 0.2)
	local light = Instance.new("SpotLight")
	light.Face = Enum.NormalId.Bottom
	light.Angle = cfg.lightAngle
	light.Range = cfg.lightRange
	light.Brightness = cfg.lightBrightness
	light.Color = cfg.beamColor
	light.Shadows = false
	light.Enabled = false
	light.Parent = lamp
	lamp.Parent = folder

	local highlight = Instance.new("Highlight")
	highlight.Name = `RankUpPop_{i}`
	highlight.FillColor = cfg.popColor
	highlight.OutlineColor = cfg.popColor
	highlight.DepthMode = Enum.HighlightDepthMode.Occluded
	highlight.Enabled = false
	highlight.Parent = folder

	return { beam = beam, lamp = lamp, light = light, highlight = highlight, busy = false }
end

local function takeRig(): Rig?
	for _, rig in rigs do
		if not rig.busy then
			rig.busy = true
			return rig
		end
	end
	return nil
end

local function releaseRig(rig: Rig)
	rig.busy = false
	rig.beam.Transparency = 1
	rig.beam.CFrame = HIDDEN_CFRAME
	rig.lamp.CFrame = HIDDEN_CFRAME
	rig.light.Enabled = false
	rig.highlight.Enabled = false
	rig.highlight.Adornee = nil
end

local function rootOf(player: Player?): (Model?, BasePart?)
	local character = player and player.Character
	if not character then
		return nil, nil
	end
	local root = character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return character, root
	end
	return nil, nil
end

local function makeLabel(name: string, size: UDim2, position: UDim2, textSize: number): TextLabel
	local label = Instance.new("TextLabel")
	label.Name = name
	label.BackgroundTransparency = 1
	label.AnchorPoint = Vector2.new(0.5, 0.5)
	label.Size = size
	label.Position = position
	label.Font = Enum.Font.FredokaOne
	label.TextScaled = true
	label.TextColor3 = Color3.new(1, 1, 1)
	label.TextStrokeTransparency = 0.2
	local limit = Instance.new("UITextSizeConstraint")
	limit.MaxTextSize = textSize
	limit.Parent = label
	return label
end

local function buildRankGui()
	rankGui = Instance.new("ScreenGui")
	rankGui.Name = "RankUpCinematic"
	rankGui.ResetOnSpawn = false
	rankGui.IgnoreGuiInset = true
	rankGui.DisplayOrder = 40
	rankGui.Enabled = false

	rankTitle = makeLabel("Title", UDim2.fromScale(0.8, 0.1), UDim2.fromScale(0.5, 0.16), 64)
	rankTitle.TextColor3 = EffectsConfig.RankUp.popColor
	rankTitle.Text = EffectsConfig.RankUp.titleText
	rankTitle.Parent = rankGui

	rankName = makeLabel("RankName", UDim2.fromScale(0.8, 0.07), UDim2.fromScale(0.5, 0.25), 44)
	rankName.Parent = rankGui

	skipButton = Instance.new("TextButton")
	skipButton.Name = "Skip"
	skipButton.AnchorPoint = Vector2.new(1, 1)
	skipButton.Position = UDim2.new(1, -24, 1, -24)
	skipButton.Size = UDim2.fromOffset(120, 48) -- thumb-sized on phones
	skipButton.BackgroundColor3 = Color3.fromRGB(30, 30, 40)
	skipButton.BackgroundTransparency = 0.25
	skipButton.Font = Enum.Font.FredokaOne
	skipButton.TextSize = 24
	skipButton.TextColor3 = Color3.new(1, 1, 1)
	skipButton.Text = "Skip"
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 12)
	corner.Parent = skipButton
	skipButton.Parent = rankGui
end

local function rankDisplayName(rank: number): string
	local row = EconomyConfig.RANKS[rank]
	return if row then row.name else `Rank {rank}`
end

-- Camera ---------------------------------------------------------------------------------------------------

local function returnCFrame(saved: SavedCamera, rootPos: Vector3): CFrame
	local pos = rootPos + saved.offset
	return CFrame.lookAt(pos, pos + saved.look)
end

local function restoreCamera(saved: SavedCamera)
	local camera = Workspace.CurrentCamera
	if not camera then
		return
	end
	local subject = saved.subject
	if subject == nil or not subject:IsDescendantOf(game) then
		local character = localPlayer.Character
		subject = if character then character:FindFirstChildOfClass("Humanoid") else nil
	end
	camera.CameraType = saved.cameraType
	if subject then
		camera.CameraSubject = subject
	end
	camera.FieldOfView = saved.fov
end

local function saveCamera(root: BasePart): SavedCamera?
	local camera = Workspace.CurrentCamera
	if not camera then
		return nil
	end
	local offset = camera.CFrame.Position - root.Position
	local saved: SavedCamera = {
		cameraType = camera.CameraType,
		subject = camera.CameraSubject,
		fov = camera.FieldOfView,
		offset = offset,
		look = camera.CFrame.LookVector,
		startAngle = math.atan2(offset.Z, offset.X),
	}
	-- A camera that is already scripted (another cutscene) is left alone.
	if saved.cameraType == Enum.CameraType.Scriptable then
		return nil
	end
	camera.CameraType = Enum.CameraType.Scriptable
	return saved
end

local function driveCamera(m: Moment, saved: SavedCamera, t: number)
	local camera = Workspace.CurrentCamera
	if not camera then
		return
	end
	local cfg = EffectsConfig.RankUp
	local rootPos = m.root.Position
	local orbit = CFrame.lookAt(
		EffectsConfig.orbitPosition(rootPos, saved.startAngle, t),
		rootPos + Vector3.new(0, cfg.lookHeight, 0)
	)
	local a = 1
	if t < cfg.blendIn then
		a = EffectsConfig.smooth(t / cfg.blendIn)
	elseif t > cfg.duration - cfg.blendOut then
		a = EffectsConfig.smooth((cfg.duration - t) / cfg.blendOut)
	end
	camera.CFrame = returnCFrame(saved, rootPos):Lerp(orbit, a)
	camera.FieldOfView = saved.fov + (cfg.orbitFov - saved.fov) * a
end

-- Moments --------------------------------------------------------------------------------------------------

local onRenderStep: (dt: number) -> ()

local function bind()
	if not bound then
		bound = true
		RunService:BindToRenderStep(RENDER_STEP_NAME, Enum.RenderPriority.Camera.Value + 1, onRenderStep)
	end
end

local function unbindIfIdle()
	if bound and momentCount == 0 then
		bound = false
		RunService:UnbindFromRenderStep(RENDER_STEP_NAME)
	end
end

local function endMoment(m: Moment)
	if moments[m.userId] ~= m then
		return
	end
	moments[m.userId] = nil
	momentCount -= 1
	if m.rig then
		releaseRig(m.rig)
		m.rig = nil
	end
	if m.camera then
		restoreCamera(m.camera)
		m.camera = nil
		rankGui.Enabled = false
	end
	unbindIfIdle()
end

local function pop(m: Moment)
	m.popped = true
	local rig = m.rig
	if rig then
		rig.highlight.Adornee = m.character
		rig.highlight.FillTransparency = 0.15
		rig.highlight.OutlineTransparency = 0
		rig.highlight.Enabled = true
	end
end

local function stepMoment(m: Moment, now: number)
	local cfg = EffectsConfig.RankUp
	if m.root.Parent == nil or not m.character:IsDescendantOf(Workspace) then
		endMoment(m) -- died, respawned or streamed out
		return
	end
	local t = now - m.startedAt
	if t >= cfg.duration then
		endMoment(m)
		return
	end
	local rootPos = m.root.Position

	if not m.popped and t >= cfg.popAt then
		pop(m)
	end

	local bursts = cfg.confettiBursts
	while m.nextBurst <= #bursts and t >= bursts[m.nextBurst] do
		m.nextBurst += 1
		local count = if m.camera then cfg.confettiPerBurst else cfg.confettiNearbyPerBurst
		EffectPool.emit(confettiPool, rootPos + Vector3.new(0, cfg.confettiHeight, 0), count)
	end

	local rig = m.rig
	if rig then
		-- Beam fades in over blendIn and out over blendOut; it follows the character.
		local strength = math.min(
			EffectsConfig.smooth(t / cfg.blendIn),
			EffectsConfig.smooth((cfg.duration - t) / cfg.blendOut)
		)
		rig.beam.Transparency = 1 - (1 - cfg.beamTransparency) * strength
		rig.beam.CFrame = CFrame.new(rootPos + Vector3.new(0, cfg.beamHeight / 2 - 3, 0))
			* CFrame.Angles(0, 0, math.pi / 2)
		rig.lamp.CFrame = CFrame.new(rootPos + Vector3.new(0, 12, 0))
		rig.light.Enabled = true
		rig.light.Brightness = cfg.lightBrightness * strength
		if m.popped then
			local fade = math.clamp((t - cfg.popAt) / cfg.popFade, 0, 1)
			rig.highlight.FillTransparency = 0.15 + 0.85 * fade
			rig.highlight.OutlineTransparency = fade
			if fade >= 1 then
				rig.highlight.Enabled = false
			end
		end
	end

	local saved = m.camera
	if saved then
		driveCamera(m, saved, t)
		local textFade = math.max(0, (t - (cfg.duration - cfg.blendOut)) / cfg.blendOut)
		rankTitle.TextTransparency = textFade
		rankTitle.TextStrokeTransparency = 0.2 + 0.8 * textFade
		rankName.TextTransparency = textFade
		rankName.TextStrokeTransparency = 0.2 + 0.8 * textFade
	end
end

onRenderStep = function(_dt: number)
	local now = os.clock()
	for _, m in moments do
		stepMoment(m, now) -- endMoment only clears the visited key, which is safe during iteration
	end
end

local function localInDuel(): boolean
	return localPlayer:GetAttribute(Types.PlayerAttr.InDuel) == true
		or localPlayer:GetAttribute(Types.PlayerAttr.Activity) == "Duel"
end

local function startRankUp(userId: number, rank: number)
	local cfg = EffectsConfig.RankUp
	local player = Players:GetPlayerByUserId(userId)
	local character, root = rootOf(player)
	if not character or not root then
		return
	end
	local isLocal = player == localPlayer
	local camera = Workspace.CurrentCamera
	if
		not isLocal
		and (not camera or (camera.CFrame.Position - root.Position).Magnitude > cfg.nearbyDistance)
	then
		return
	end

	local existing = moments[userId]
	if existing then
		-- Another rank-up while one plays (a big MP jump): restart the moment, keep the saved camera.
		existing.rank = rank
		existing.startedAt = os.clock()
		existing.nextBurst = 1
		existing.popped = false
		if existing.camera then
			rankName.Text = rankDisplayName(rank)
		end
		return
	end

	local m: Moment = {
		userId = userId,
		rank = rank,
		root = root,
		character = character,
		rig = takeRig(),
		startedAt = os.clock(),
		nextBurst = 1,
		popped = false,
		camera = nil,
	}
	if isLocal and not localInDuel() then
		m.camera = saveCamera(root)
	end
	if m.camera then
		rankName.Text = rankDisplayName(rank)
		rankTitle.TextTransparency = 0
		rankName.TextTransparency = 0
		rankGui.Enabled = true
	end
	moments[userId] = m
	momentCount += 1
	bind()
end

local function skipRankUp()
	local m = moments[localPlayer.UserId]
	if not m or not m.camera then
		return
	end
	local cfg = EffectsConfig.RankUp
	if not m.popped then
		pop(m) -- the look still pops, just sooner
	end
	m.nextBurst = #cfg.confettiBursts + 1
	-- Jump straight into the blend back to the player's camera.
	local t = os.clock() - m.startedAt
	local target = cfg.duration - cfg.blendOut
	if t < target then
		m.startedAt -= target - t
	end
end

-- Hatch reveal (T-045) --------------------------------------------------------------------------------------
-- Plays from `HatchResult` (sent to the hatcher only). It shows exactly the pets the server rolled, in order;
-- nothing here rolls, picks or changes a result. EggController (UI) shows the same payload in its own panel.

type Reveal = {
	petId: string,
	rarity: string,
	isNew: boolean,
	autoDeleted: boolean,
	pity: boolean,
}

type Card = {
	frame: Frame,
	scale: UIScale,
	stroke: UIStroke,
	ball: Frame,
	name: TextLabel,
	rarity: TextLabel,
	tag: TextLabel,
}

local hatchGui: ScreenGui
local hatchCatcher: TextButton -- full-screen dim; any tap/click on it is Skip (and never reaches TapController)
local hatchEgg: Frame
local hatchFlash: Frame
local hatchHint: TextLabel
local cards: { Card } = {}
local hatchQueue: { { Reveal } } = {}
local hatchConn: RBXScriptConnection? = nil
local hatchReveals: { Reveal } = {}
local hatchStartedAt = 0
local hatchEndsAt = 0

local function easeOutBack(x: number): number
	local c1 = 1.70158
	local c3 = c1 + 1
	local u = math.clamp(x, 0, 1) - 1
	return 1 + c3 * u * u * u + c1 * u * u
end

local function rarityColor(rarity: string): Color3
	return EffectsConfig.RarityColors[rarity] or EffectsConfig.DEFAULT_RARITY_COLOR
end

local function petDisplayName(petId: string): string
	local pet = EconomyConfig.PETS[petId]
	return if pet and type(pet.name) == "string" then pet.name else petId
end

local function corner(parent: Instance, scale: number)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(scale, 0)
	c.Parent = parent
end

local function buildCard(i: number): Card
	local frame = Instance.new("Frame")
	frame.Name = `Card_{i}`
	frame.AnchorPoint = Vector2.new(0.5, 0.5)
	frame.Size = UDim2.fromScale(0.24, 0.42)
	frame.BackgroundColor3 = Color3.fromRGB(28, 24, 44)
	frame.Visible = false
	corner(frame, 0.08)
	local aspect = Instance.new("UIAspectRatioConstraint")
	aspect.AspectRatio = 0.72
	aspect.Parent = frame
	local scale = Instance.new("UIScale")
	scale.Scale = 0
	scale.Parent = frame
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 4
	stroke.Parent = frame

	local ball = Instance.new("Frame")
	ball.Name = "Pet"
	ball.AnchorPoint = Vector2.new(0.5, 0.5)
	ball.Position = UDim2.fromScale(0.5, 0.34)
	ball.Size = UDim2.fromScale(0.5, 0.5)
	local ballAspect = Instance.new("UIAspectRatioConstraint")
	ballAspect.AspectRatio = 1
	ballAspect.Parent = ball
	corner(ball, 0.5)
	ball.Parent = frame

	local name = makeLabel("PetName", UDim2.fromScale(0.9, 0.16), UDim2.fromScale(0.5, 0.68), 30)
	name.Parent = frame
	local rarity = makeLabel("Rarity", UDim2.fromScale(0.9, 0.1), UDim2.fromScale(0.5, 0.8), 22)
	rarity.Parent = frame
	local tag = makeLabel("Tag", UDim2.fromScale(0.9, 0.09), UDim2.fromScale(0.5, 0.91), 20)
	tag.TextColor3 = Color3.fromRGB(255, 240, 120)
	tag.Parent = frame

	return {
		frame = frame,
		scale = scale,
		stroke = stroke,
		ball = ball,
		name = name,
		rarity = rarity,
		tag = tag,
	}
end

local function buildHatchGui()
	local cfg = EffectsConfig.Hatch
	hatchGui = Instance.new("ScreenGui")
	hatchGui.Name = "HatchReveal"
	hatchGui.ResetOnSpawn = false
	hatchGui.IgnoreGuiInset = true
	hatchGui.DisplayOrder = 45
	hatchGui.Enabled = false

	hatchCatcher = Instance.new("TextButton")
	hatchCatcher.Name = "Dim"
	hatchCatcher.Size = UDim2.fromScale(1, 1)
	hatchCatcher.BackgroundColor3 = Color3.new(0, 0, 0)
	hatchCatcher.BackgroundTransparency = 0.45
	hatchCatcher.AutoButtonColor = false
	hatchCatcher.Text = ""
	hatchCatcher.Parent = hatchGui

	hatchEgg = Instance.new("Frame")
	hatchEgg.Name = "Egg"
	hatchEgg.AnchorPoint = Vector2.new(0.5, 0.5)
	hatchEgg.Position = UDim2.fromScale(0.5, 0.5)
	hatchEgg.Size = UDim2.fromScale(0.2, 0.36)
	hatchEgg.BackgroundColor3 = cfg.eggColor
	local eggAspect = Instance.new("UIAspectRatioConstraint")
	eggAspect.AspectRatio = 0.78
	eggAspect.Parent = hatchEgg
	corner(hatchEgg, 0.5)
	local eggStroke = Instance.new("UIStroke")
	eggStroke.Thickness = 4
	eggStroke.Color = Color3.fromRGB(255, 255, 255)
	eggStroke.Parent = hatchEgg
	hatchEgg.Parent = hatchGui

	for i = 1, cfg.maxReveals do
		local card = buildCard(i)
		card.frame.Parent = hatchGui
		cards[i] = card
	end

	hatchFlash = Instance.new("Frame")
	hatchFlash.Name = "Flash"
	hatchFlash.Size = UDim2.fromScale(1, 1)
	hatchFlash.BackgroundColor3 = Color3.new(1, 1, 1)
	hatchFlash.BackgroundTransparency = 1
	hatchFlash.Active = false
	hatchFlash.Parent = hatchGui

	hatchHint = makeLabel("Hint", UDim2.fromScale(0.6, 0.05), UDim2.fromScale(0.5, 0.92), 22)
	hatchHint.Text = "Tap to skip"
	hatchHint.Parent = hatchGui
end

-- Pure-ish payload check: keeps only well-formed entries, at most Hatch.maxReveals, in server order.
local function readReveals(payload: unknown): { Reveal }
	local out: { Reveal } = {}
	if type(payload) ~= "table" then
		return out
	end
	local pets = (payload :: { [string]: unknown }).pets
	if type(pets) ~= "table" then
		return out
	end
	for _, entry in ipairs(pets :: { unknown }) do
		if type(entry) == "table" then
			local e = entry :: { [string]: unknown }
			local petId = e.petId
			if type(petId) == "string" and #petId <= 32 then
				local pet = EconomyConfig.PETS[petId]
				local rarity = if type(e.rarity) == "string"
					then e.rarity :: string
					elseif pet then pet.rarity
					else "Common"
				table.insert(out, {
					petId = petId,
					rarity = rarity,
					isNew = e.isNew == true,
					autoDeleted = e.autoDeleted == true,
					pity = e.pity == true,
				})
				if #out >= EffectsConfig.Hatch.maxReveals then
					break
				end
			end
		end
	end
	return out
end

local function fillCards(reveals: { Reveal })
	local n = #reveals
	for i, card in cards do
		local r = reveals[i]
		card.frame.Visible = false
		card.scale.Scale = 0
		if r then
			local color = rarityColor(r.rarity)
			card.frame.Position = UDim2.fromScale(0.5 + (i - (n + 1) / 2) * 0.27, 0.5)
			card.stroke.Color = color
			card.ball.BackgroundColor3 = color
			card.ball.BackgroundTransparency = if r.autoDeleted then 0.6 else 0
			card.name.Text = petDisplayName(r.petId)
			card.rarity.Text = r.rarity
			card.rarity.TextColor3 = color
			local tags: { string } = {}
			if r.pity then
				table.insert(tags, "PITY!")
			end
			if r.isNew then
				table.insert(tags, "NEW!")
			end
			if r.autoDeleted then
				table.insert(tags, "Auto-deleted")
			end
			card.tag.Text = table.concat(tags, "  ")
		end
	end
end

local startNextHatch: () -> ()

local function finishHatch()
	local conn = hatchConn
	if conn then
		conn:Disconnect()
		hatchConn = nil
	end
	hatchGui.Enabled = false
	startNextHatch()
end

local function stepHatch()
	local cfg = EffectsConfig.Hatch
	local now = os.clock()
	if now >= hatchEndsAt then
		finishHatch()
		return
	end
	local t = now - hatchStartedAt
	local revealStart = EffectsConfig.hatchTimes(#hatchReveals)

	-- Egg wobble that grows, then the egg is gone under the flash.
	if t < cfg.wobbleTime then
		local k = t / cfg.wobbleTime
		hatchEgg.Visible = true
		hatchEgg.Rotation = math.sin(t * cfg.wobbleSpeed * (0.5 + k)) * cfg.wobbleDegrees * k
	else
		hatchEgg.Visible = false
	end
	if t >= cfg.wobbleTime and t < revealStart then
		hatchFlash.BackgroundTransparency = (t - cfg.wobbleTime) / cfg.flashTime
	else
		hatchFlash.BackgroundTransparency = 1
	end

	for i, card in cards do
		if hatchReveals[i] then
			local popStart = revealStart + (i - 1) * cfg.revealStagger
			if t >= popStart then
				card.frame.Visible = true
				card.scale.Scale = easeOutBack((t - popStart) / cfg.popTime)
			end
		end
	end
end

startNextHatch = function()
	local reveals = table.remove(hatchQueue, 1)
	if not reveals then
		return
	end
	hatchReveals = reveals
	fillCards(reveals)
	local _, total = EffectsConfig.hatchTimes(#reveals)
	hatchStartedAt = os.clock()
	hatchEndsAt = hatchStartedAt + total
	hatchEgg.Rotation = 0
	hatchFlash.BackgroundTransparency = 1
	hatchGui.Enabled = true
	hatchConn = RunService.RenderStepped:Connect(stepHatch)
end

-- First press: jump to all cards shown, then close after Hatch.skipHoldTime. Second press: close now.
local function skipHatch()
	if not hatchConn then
		return
	end
	local cfg = EffectsConfig.Hatch
	local now = os.clock()
	local revealStart = EffectsConfig.hatchTimes(#hatchReveals)
	local allShown = revealStart + (#hatchReveals - 1) * cfg.revealStagger + cfg.popTime
	if now - hatchStartedAt >= allShown then
		hatchEndsAt = now
	else
		hatchStartedAt = now - allShown
		hatchEndsAt = math.min(hatchEndsAt, now + cfg.skipHoldTime)
	end
	stepHatch()
end

local function onHatchResult(payload: unknown)
	local reveals = readReveals(payload)
	if #reveals == 0 then
		return
	end
	if #hatchQueue >= EffectsConfig.Hatch.maxQueued then
		return -- the pets are in the inventory anyway; never stack long queues of animations
	end
	table.insert(hatchQueue, reveals)
	if hatchConn then
		skipHatch() -- a newer hatch is waiting: hurry the current one along
	else
		startNextHatch()
	end
end

local function onPlayEffect(effect: unknown, payload: unknown)
	if effect ~= "RankUp" or type(payload) ~= "table" then
		return
	end
	local p = payload :: { [string]: unknown }
	local userId, rank = p.userId, p.rank
	if type(userId) ~= "number" or type(rank) ~= "number" or rank ~= rank then
		return
	end
	startRankUp(userId, math.floor(rank))
end

function CinematicController:Init()
	folder = Instance.new("Folder")
	folder.Name = "ClientCinematics"
	local pools = EffectsConfig.Pools
	confettiPool = EffectPool.new("Confetti", pools.Confetti.size, pools.Confetti.look, folder)
	for i = 1, EffectsConfig.RankUp.maxRigs do
		rigs[i] = buildRig(i)
	end
	folder.Parent = Workspace
	buildRankGui()
	skipButton.Activated:Connect(skipRankUp)
	buildHatchGui()
	hatchCatcher.Activated:Connect(skipHatch)
end

function CinematicController:Start()
	-- WaitForChild calls yield, so they run here, never in Init.
	local playerGui = localPlayer:WaitForChild("PlayerGui")
	rankGui.Parent = playerGui
	hatchGui.Parent = playerGui
	Remotes.getEvent("PlayEffect").OnClientEvent:Connect(onPlayEffect)
	Remotes.getEvent("HatchResult").OnClientEvent:Connect(onHatchResult)
	localPlayer.CharacterRemoving:Connect(function()
		local m = moments[localPlayer.UserId]
		if m then
			endMoment(m)
		end
	end)
end

return CinematicController
