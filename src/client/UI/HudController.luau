--!strict
-- HudController: MP / coins / rank, the boss meter, first-minute guidance, leaderboard toggle and shop buttons.
-- Owned by systems-programmer. Contract: architecture 1d #25, GDD 9 (first 5 minutes).
--
-- * Reads only server-written attributes and shared config (GameData). The only remote it fires is
--   RequestBossFight from the MOG button (T-015); BossService re-checks id, world, distance, MP and activity.
--   Every number goes through NumberFormat.
-- * MOG button (GDD 4.4): shown when a boss stage of the current world is within INTERACT_RANGE. Grey
--   "Need 600 MP (you: 412)" below the threshold, pulsing "MOG!" at or above it, "MOGGING..." during a fight.
-- * First minute (GDD 9): pulsing "TAP to power up!" with a tap ring until the first tap; meter "100 MP to beat
--   Sleepy Sid"; when full, "GO MOG HIM!"; a light beam from the player to Sid's stage until the first win.
-- * Shop buttons are hidden until FirstWin (GDD 8a). The Robux shop button arrives with T-057; this HUD has no
--   purchase prompt of any kind.
-- * The Roblox player list starts collapsed; the "Players" button toggles it.
-- * T-034: "Pods" button (ShopController pod shop), "Settings" button (SettingsController), a pod income line
--   from IdleMpPerSec, and a rebirth button that pulses "REBIRTH READY" when Coins >= RebirthCost; it opens
--   Panels/RebirthPanel (confirm screen, the only RequestRebirth sender).
-- * Updates are event-driven (attribute changes, max 5 Hz from the server) plus one 2 Hz check for the arrow.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterGui = game:GetService("StarterGui")
local TweenService = game:GetService("TweenService")

local Contracts = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Contracts")
local NumberFormat = require(Contracts:WaitForChild("NumberFormat"))
local Remotes = require(Contracts:WaitForChild("Remotes"))
local Types = require(Contracts:WaitForChild("Types"))

local GameData = require(script.Parent.Util.GameData)
local RebirthPanel = require(script.Parent.Panels.RebirthPanel)
local Ui = require(script.Parent.Util.Ui)
local UiEvents = require(script.Parent.Util.UiEvents)

local Attr = Types.PlayerAttr
local Theme = Ui.Theme

local ARROW_HIDE_DISTANCE = 12 -- studs: close enough to the stage, the arrow goes away
local ARROW_CHECK_SEC = 0.5
local ARROW_MODEL_LIFT = 3 -- studs above a Model stage's pivot
local MOG_CHECK_SEC = 0.25
local MOG_DEBOUNCE_SEC = 1

local HudController = {}

type Elements = {
	screen: ScreenGui,
	mpLabel: TextLabel,
	coinsLabel: TextLabel,
	rankLabel: TextLabel,
	bossMeter: Frame,
	bossFill: Frame,
	bossText: TextLabel,
	rankMeter: Frame,
	rankFill: Frame,
	rankText: TextLabel,
	tapHint: Frame,
	shopButtons: Frame,
	playersButton: TextButton,
	mogButton: TextButton,
	mogScale: UIScale,
	mogPulse: Tween,
	idleLabel: TextLabel,
	rebirthButton: TextButton,
	rebirthScale: UIScale,
	rebirthPulse: Tween,
}

local ui: Elements? = nil
local hasTapped = false
local playerListOpen = false
local mogBoss: GameData.Boss? = nil -- boss whose stage is in range, nil = button hidden
local lastMogAt = 0

-- Arrow (client-only Beam; no per-frame work)
local stageAttachment: Attachment? = nil
local rootAttachment: Attachment? = nil
local beam: Beam? = nil

local function pulse(instance: Instance, props: { [string]: any }, seconds: number): Tween
	local tween = TweenService:Create(
		instance,
		TweenInfo.new(seconds, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
		props
	)
	tween:Play()
	return tween
end

local function build(): Elements
	local screen = Ui.screen("Hud", 10)

	-- Top-centre column: stats, boss meter, rank meter.
	local top = Ui.new("Frame", {
		Name = "Top",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 4),
		Size = UDim2.fromScale(0.62, 0.2),
		Parent = screen,
	}, {
		Ui.sizeLimit(280, 110, 620, 200),
		Ui.new("UIListLayout", {
			FillDirection = Enum.FillDirection.Vertical,
			HorizontalAlignment = Enum.HorizontalAlignment.Center,
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0.03, 0),
		}),
	})

	local stats = Ui.new("Frame", {
		Name = "Stats",
		BackgroundColor3 = Theme.panel,
		BackgroundTransparency = 0.15,
		Size = UDim2.fromScale(1, 0.4),
		LayoutOrder = 1,
		Parent = top,
	}, {
		Ui.corner(0.3),
		Ui.stroke(),
		Ui.new("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal,
			HorizontalAlignment = Enum.HorizontalAlignment.Center,
			VerticalAlignment = Enum.VerticalAlignment.Center,
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
	})
	local function stat(name: string, order: number, color: Color3, width: number): TextLabel
		local label = Ui.label({
			Name = name,
			LayoutOrder = order,
			Size = UDim2.fromScale(width, 0.75),
			TextColor3 = color,
			Parent = stats,
		})
		Ui.textLimit(30).Parent = label
		return label
	end
	local mpLabel = stat("Mp", 1, Theme.accent, 0.36)
	local coinsLabel = stat("Coins", 2, Theme.coins, 0.3)
	local rankLabel = stat("Rank", 3, Theme.text, 0.32)

	local bossMeter, bossFill, bossText = Ui.meter({
		Name = "BossMeter",
		Size = UDim2.fromScale(0.92, 0.27),
		LayoutOrder = 2,
		Parent = top,
	}, Theme.accent)
	Ui.textLimit(26).Parent = bossText

	local rankMeter, rankFill, rankText = Ui.meter({
		Name = "RankMeter",
		Size = UDim2.fromScale(0.7, 0.2),
		LayoutOrder = 3,
		Visible = false,
		Parent = top,
	}, Theme.good)
	Ui.textLimit(20).Parent = rankText

	-- Pod income while standing in an owned pod (IdleService's IdleMpPerSec, GDD 4.3).
	local idleLabel = Ui.label({
		Name = "IdleMp",
		Size = UDim2.fromScale(0.6, 0.16),
		LayoutOrder = 4,
		TextColor3 = Theme.good,
		Visible = false,
		Parent = top,
	})
	Ui.textLimit(20).Parent = idleLabel

	-- Tap hint: pulsing text and a tap ring in the lower middle of the screen.
	local tapHint = Ui.new("Frame", {
		Name = "TapHint",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.6),
		Size = UDim2.fromScale(0.6, 0.16),
		Active = false,
		Parent = screen,
	}, { Ui.sizeLimit(240, 70, 560, 150) })
	local hintText = Ui.label({
		Text = "TAP to power up!",
		Size = UDim2.fromScale(1, 0.55),
		TextColor3 = Theme.accent,
		Parent = tapHint,
	})
	local ring = Ui.new("Frame", {
		Name = "TapRing",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.fromScale(0.5, 0.6),
		Size = UDim2.fromScale(0.4, 0.4),
		Parent = tapHint,
	}, {
		Ui.new("UIAspectRatioConstraint", { AspectRatio = 1 }),
		Ui.corner(0.5),
		Ui.new("UIStroke", { Color = Theme.text, Thickness = 4 }),
	})
	pulse(hintText, { Rotation = 3 }, 0.6)
	pulse(ring, { Size = UDim2.fromScale(0.3, 0.3) }, 0.5)

	-- Top-right: player-list toggle (the list starts collapsed, GDD 9).
	local playersButton = Ui.button({
		Name = "PlayersButton",
		Text = "Players",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -6, 0, 4),
		Size = UDim2.fromScale(0.13, 0.07),
		Parent = screen,
	})
	Ui.textLimit(20).Parent = playersButton

	-- Top-right, under Players: the Settings button (always shown; it sells nothing).
	local settingsButton = Ui.button({
		Name = "SettingsButton",
		Text = "Settings",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -6, 0.07, 12),
		Size = UDim2.fromScale(0.13, 0.07),
		Parent = screen,
	})
	Ui.textLimit(20).Parent = settingsButton
	settingsButton.Activated:Connect(function()
		UiEvents.fireOpenPanel("Settings")
	end)

	-- Right side, above the mobile jump button: panel buttons in a column, hidden until FirstWin (GDD 8a, 9:
	-- small, not blinking).
	local shopButtons = Ui.new("Frame", {
		Name = "ShopButtons",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -8, 0.5, 0),
		Size = UDim2.fromScale(0.13, 0.3),
		Visible = false,
		Parent = screen,
	}, {
		Ui.sizeLimit(88, 150, 180, 280),
		Ui.new("UIListLayout", {
			FillDirection = Enum.FillDirection.Vertical,
			HorizontalAlignment = Enum.HorizontalAlignment.Right,
			VerticalAlignment = Enum.VerticalAlignment.Center,
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0.04, 0),
		}),
	})
	local function panelButton(name: string, text: string, order: number, color: Color3, panel: string)
		local button = Ui.button({
			Name = name,
			Text = text,
			LayoutOrder = order,
			Size = UDim2.fromScale(1, 0.3),
			BackgroundColor3 = color,
			Parent = shopButtons,
		})
		Ui.textLimit(22).Parent = button
		button.Activated:Connect(function()
			UiEvents.fireOpenPanel(panel)
		end)
	end
	panelButton("ToolsButton", "Tools", 1, Theme.good, "Tools")
	panelButton("PodsButton", "Pods", 2, Theme.good, "Pods")

	-- Top-left: rebirth button (after FirstWin). "REBIRTH READY" pulses when coins reach the cost (GDD 4.5).
	local rebirthButton = Ui.button({
		Name = "RebirthButton",
		Text = "Rebirth",
		AnchorPoint = Vector2.new(0, 0),
		Position = UDim2.new(0, 6, 0, 4),
		Size = UDim2.fromScale(0.16, 0.08),
		Visible = false,
		Parent = screen,
	})
	Ui.textLimit(22).Parent = rebirthButton
	local rebirthScale = Ui.new("UIScale", { Parent = rebirthButton })
	local rebirthPulse = pulse(rebirthScale, { Scale = 1.1 }, 0.5)
	rebirthPulse:Cancel() -- plays only while a rebirth is affordable
	rebirthButton.Activated:Connect(function()
		UiEvents.fireOpenPanel("Rebirth")
	end)

	-- Bottom-centre: the giant MOG button (hidden until a boss stage is in range).
	local mogButton = Ui.button({
		Name = "MogButton",
		Text = "MOG!",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -10),
		Size = UDim2.fromScale(0.34, 0.12),
		BackgroundColor3 = Theme.grey,
		Visible = false,
		Parent = screen,
	})
	Ui.sizeLimit(180, 56, 420, 110).Parent = mogButton
	Ui.textLimit(34).Parent = mogButton
	local mogScale = Ui.new("UIScale", { Parent = mogButton })
	local mogPulse = pulse(mogScale, { Scale = 1.08 }, 0.45)
	mogPulse:Cancel() -- plays only while the button is active

	return {
		screen = screen,
		mpLabel = mpLabel,
		coinsLabel = coinsLabel,
		rankLabel = rankLabel,
		bossMeter = bossMeter,
		bossFill = bossFill,
		bossText = bossText,
		rankMeter = rankMeter,
		rankFill = rankFill,
		rankText = rankText,
		tapHint = tapHint,
		shopButtons = shopButtons,
		playersButton = playersButton,
		mogButton = mogButton,
		mogScale = mogScale,
		mogPulse = mogPulse,
		idleLabel = idleLabel,
		rebirthButton = rebirthButton,
		rebirthScale = rebirthScale,
		rebirthPulse = rebirthPulse,
	}
end

-- Boss the meter points at: Sleepy Sid (weakest in the world) until the first win, then the weakest boss the
-- player can't beat yet. nil = every boss in this world is beatable.
local function meterTarget(): GameData.Boss?
	local bosses = GameData.bossesInWorld(Ui.numAttr(Attr.WorldId, 1))
	if not Ui.boolAttr(Attr.FirstWin) then
		return bosses[1]
	end
	local mp = Ui.numAttr(Attr.Mp, 0)
	for _, boss in bosses do
		if boss.need > mp then
			return boss
		end
	end
	return nil
end

local function setFill(fill: Frame, ratio: number)
	local clamped = if ratio == ratio then math.clamp(ratio, 0, 1) else 0
	fill.Size = UDim2.fromScale(clamped, 1)
end

local function refreshRank(elements: Elements, firstWin: boolean)
	local ranks = GameData.ranks()
	local rank = math.floor(Ui.numAttr(Attr.Rank, 1))
	local current = ranks[rank]
	elements.rankLabel.Text = if current then current.name else `Rank {rank}`
	local nextRank = ranks[rank + 1]
	elements.rankMeter.Visible = firstWin and current ~= nil and nextRank ~= nil
	if current and nextRank then
		local lifetime = Ui.numAttr(Attr.LifetimeMp, 0)
		setFill(elements.rankFill, (lifetime - current.need) / math.max(1, nextRank.need - current.need))
		elements.rankText.Text = `{nextRank.name} at {NumberFormat.abbreviate(nextRank.need)} MP`
	end
end

local function refresh()
	local elements = ui
	if elements == nil then
		return
	end
	local mp = Ui.numAttr(Attr.Mp, 0)
	local firstWin = Ui.boolAttr(Attr.FirstWin)
	elements.mpLabel.Text = NumberFormat.abbreviate(mp) .. " MP"
	elements.coinsLabel.Text = NumberFormat.abbreviate(Ui.numAttr(Attr.Coins, 0)) .. " Coins"
	refreshRank(elements, firstWin)

	local target = meterTarget()
	elements.bossMeter.Visible = target ~= nil
	if target then
		setFill(elements.bossFill, mp / math.max(1, target.need))
		if mp >= target.need then
			elements.bossText.Text = "GO MOG HIM!"
			elements.bossFill.BackgroundColor3 = Theme.good
		else
			elements.bossText.Text = `{NumberFormat.abbreviate(target.need)} MP to beat {target.name}`
			elements.bossFill.BackgroundColor3 = Theme.accent
		end
	end

	elements.tapHint.Visible = not hasTapped and not firstWin
	elements.shopButtons.Visible = firstWin

	local idle = Ui.numAttr(Attr.IdleMpPerSec, 0)
	elements.idleLabel.Visible = idle > 0
	if idle > 0 then
		elements.idleLabel.Text = `Pod: +{NumberFormat.abbreviate(idle)} MP/s`
	end

	local rebirthButton = elements.rebirthButton
	rebirthButton.Visible = firstWin or Ui.numAttr(Attr.Rebirths, 0) > 0
	if RebirthPanel.isReady() then
		rebirthButton.Text = "REBIRTH READY"
		rebirthButton.BackgroundColor3 = Theme.accent
		if elements.rebirthPulse.PlaybackState ~= Enum.PlaybackState.Playing then
			elements.rebirthPulse:Play()
		end
	else
		rebirthButton.Text = "Rebirth"
		rebirthButton.BackgroundColor3 = Theme.panelLight
		elements.rebirthPulse:Cancel()
		elements.rebirthScale.Scale = 1
	end
end

-- MOG button ------------------------------------------------------------------------------------------

-- The boss of the current world whose stage is nearest to the character, if within INTERACT_RANGE.
local function bossInRange(): GameData.Boss?
	local character = Players.LocalPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if root == nil or not root:IsA("BasePart") then
		return nil
	end
	local range = GameData.interactRange()
	local best: GameData.Boss? = nil
	local bestDistance = math.huge
	for _, boss in GameData.bossesInWorld(Ui.numAttr(Attr.WorldId, 1)) do
		local stagePos = GameData.positionOf(GameData.bossStage(boss.id))
		if stagePos then
			local distance = (stagePos - root.Position).Magnitude
			if distance <= range and distance < bestDistance then
				best, bestDistance = boss, distance
			end
		end
	end
	return best
end

local function refreshMog()
	local elements = ui
	if elements == nil then
		return
	end
	local button = elements.mogButton
	local boss = mogBoss
	local activity = Players.LocalPlayer:GetAttribute(Attr.Activity)
	if boss == nil or not Ui.boolAttr(Attr.DataLoaded) or activity == "Duel" then
		button.Visible = false
		return
	end
	button.Visible = true
	local mp = Ui.numAttr(Attr.Mp, 0)
	if activity == "BossFight" then
		button.Text = "MOGGING..."
		button.BackgroundColor3 = Theme.accent
		button.AutoButtonColor = false
		elements.mogPulse:Cancel()
		elements.mogScale.Scale = 1
	elseif mp >= boss.need then
		button.Text = `MOG {boss.name}!`
		button.BackgroundColor3 = Theme.good
		button.AutoButtonColor = true
		if elements.mogPulse.PlaybackState ~= Enum.PlaybackState.Playing then
			elements.mogPulse:Play()
		end
	else
		button.Text = `Need {NumberFormat.abbreviate(boss.need)} MP (you: {NumberFormat.abbreviate(mp)})`
		button.BackgroundColor3 = Theme.grey
		button.AutoButtonColor = false
		elements.mogPulse:Cancel()
		elements.mogScale.Scale = 1
	end
end

local function onMogPressed(requestBossFight: RemoteEvent)
	local boss = mogBoss
	if boss == nil or Ui.numAttr(Attr.Mp, 0) < boss.need then
		return
	end
	if Players.LocalPlayer:GetAttribute(Attr.Activity) == "BossFight" then
		return
	end
	local now = os.clock()
	if now - lastMogAt < MOG_DEBOUNCE_SEC then
		return
	end
	lastMogAt = now
	requestBossFight:FireServer(boss.id)
end

-- Arrow -----------------------------------------------------------------------------------------------

local function ensureBeam(): Beam?
	local character = Players.LocalPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if root == nil or not root:IsA("BasePart") then
		return nil
	end
	if rootAttachment == nil or rootAttachment.Parent ~= root then
		if rootAttachment then
			rootAttachment:Destroy()
		end
		rootAttachment = Ui.new("Attachment", {
			Name = "HudArrowFrom",
			Position = Vector3.new(0, -2.5, 0), -- near the feet so the beam reads as a floor path
			Parent = root,
		})
	end
	if beam == nil or beam.Parent ~= root then
		if beam then
			beam:Destroy()
		end
		beam = Ui.new("Beam", {
			Name = "HudArrow",
			Attachment0 = rootAttachment,
			Color = ColorSequence.new(Theme.accent),
			LightEmission = 1,
			Transparency = NumberSequence.new(0.2, 0.6),
			Width0 = 1.6,
			Width1 = 0.6,
			FaceCamera = true,
			Segments = 1,
			Enabled = false,
			Parent = root,
		})
	end
	return beam
end

local function updateArrow()
	local stage: Instance? = nil
	if not Ui.boolAttr(Attr.FirstWin) then
		local target = meterTarget()
		stage = if target then GameData.bossStage(target.id) else nil
	end
	local currentBeam = ensureBeam()
	if currentBeam == nil then
		return
	end
	-- A stage may be a Model or a BasePart (CR-4): aim at its position, hang the attachment on a part of it.
	local stagePos = GameData.positionOf(stage)
	local anchor = GameData.anchorPartOf(stage)
	if stagePos == nil or anchor == nil then
		currentBeam.Enabled = false
		return
	end
	local aim = if stage and stage:IsA("BasePart")
		then stagePos + Vector3.new(0, stage.Size.Y / 2, 0)
		else stagePos + Vector3.new(0, ARROW_MODEL_LIFT, 0)
	if stageAttachment == nil or stageAttachment.Parent ~= anchor then
		if stageAttachment then
			stageAttachment:Destroy()
		end
		stageAttachment = Ui.new("Attachment", { Name = "HudArrowTo", Parent = anchor })
	end
	local target = stageAttachment :: Attachment
	target.Position = anchor.CFrame:PointToObjectSpace(aim)
	currentBeam.Attachment1 = target
	local from = rootAttachment
	local distance = if from then (from.WorldPosition - stagePos).Magnitude else 0
	currentBeam.Enabled = distance > ARROW_HIDE_DISTANCE
end

local function clearArrow()
	if beam then
		beam:Destroy()
	end
	if rootAttachment then
		rootAttachment:Destroy()
	end
	if stageAttachment then
		stageAttachment:Destroy()
	end
	beam, rootAttachment, stageAttachment = nil, nil, nil
end

-- Lifecycle -------------------------------------------------------------------------------------------

function HudController:Init() end

function HudController:Start()
	local player = Players.LocalPlayer
	pcall(function()
		StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.PlayerList, false) -- collapsed at start (GDD 9)
	end)

	local elements = build()
	ui = elements
	elements.playersButton.Activated:Connect(function()
		playerListOpen = not playerListOpen
		pcall(function()
			StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.PlayerList, playerListOpen)
		end)
	end)

	for _, name in
		{
			Attr.Mp,
			Attr.Coins,
			Attr.Rank,
			Attr.LifetimeMp,
			Attr.FirstWin,
			Attr.WorldId,
			Attr.DataLoaded,
			Attr.IdleMpPerSec,
			Attr.Rebirths,
			Attr.RebirthCost,
		}
	do
		player:GetAttributeChangedSignal(name):Connect(refresh)
	end
	task.spawn(RebirthPanel.start) -- its own panel; waits for the RequestRebirth remote
	UiEvents.Tapped:Connect(function()
		if not hasTapped then
			hasTapped = true
			refresh()
		end
	end)
	refresh()

	local requestBossFight = Remotes.getEvent("RequestBossFight")
	elements.mogButton.Activated:Connect(function()
		onMogPressed(requestBossFight)
	end)
	for _, name in { Attr.Mp, Attr.Activity, Attr.WorldId } do
		player:GetAttributeChangedSignal(name):Connect(refreshMog)
	end
	task.spawn(function()
		while player.Parent do
			local boss = bossInRange()
			if boss ~= mogBoss then
				mogBoss = boss
				refreshMog()
			elseif boss == nil and elements.mogButton.Visible then
				refreshMog()
			end
			task.wait(MOG_CHECK_SEC)
		end
	end)

	task.spawn(function()
		while player.Parent do
			if Ui.boolAttr(Attr.FirstWin) then
				clearArrow()
				break
			end
			updateArrow()
			task.wait(ARROW_CHECK_SEC)
		end
	end)
end

return HudController
