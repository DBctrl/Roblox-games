--!strict
-- TapController: tap capture, local tap cap, TapBatch sending and the "+N" pop-ups. Owned by systems-programmer.
-- Contract: architecture 1d #26 and section 2 #1. The client sends a COUNT only, never an amount; the server's
-- TapService re-checks everything (integer 1..30, its own 12/s bucket minus AutoTapRate).
--
-- * A tap is a left click, a touch or gamepad R2 that the game did not already process (so taps on buttons,
--   the thumbstick or the jump button never count).
-- * Local cap: a token bucket at TAP_CAP_PER_SEC minus the player's AutoTapRate (burst 1 s), so the client never
--   sends taps the server would drop.
-- * Sends one TapBatch every 0.5 s while taps are pending (<= 2 msgs/s, architecture 7).
-- * "+N" uses the server-written MpPerTap attribute; 8 pooled labels, no per-tap Instance creation.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local Contracts = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Contracts")
local NumberFormat = require(Contracts:WaitForChild("NumberFormat"))
local Remotes = require(Contracts:WaitForChild("Remotes"))
local Types = require(Contracts:WaitForChild("Types"))

local GameData = require(script.Parent.Util.GameData)
local Ui = require(script.Parent.Util.Ui)
local UiEvents = require(script.Parent.Util.UiEvents)

local Attr = Types.PlayerAttr

local SEND_INTERVAL_SEC = 0.5
local TAP_BATCH_MAX = 30 -- architecture section 2 #1
local POPUP_POOL = 8
local POPUP_RISE_PX = 70
local POPUP_TIME_SEC = 0.6

local TapController = {}

local tokens = 0
local lastRefill = 0
local pending = 0
local popups: { TextLabel } = {}
local nextPopup = 1

local function capPerSec(): number
	local auto = Ui.numAttr(Attr.AutoTapRate, 0)
	return math.max(0, GameData.tapCapPerSec() - math.max(0, auto))
end

local function takeToken(): boolean
	local now = os.clock()
	local rate = capPerSec()
	tokens = math.min(rate, tokens + (now - lastRefill) * rate)
	lastRefill = now
	if tokens >= 1 then
		tokens -= 1
		return true
	end
	return false
end

local function showPopup(position: Vector2)
	local label = popups[nextPopup]
	nextPopup = nextPopup % #popups + 1
	if label == nil then
		return
	end
	local perTap = Ui.numAttr(Attr.MpPerTap, 1)
	label.Text = "+" .. NumberFormat.abbreviate(perTap)
	label.Position = UDim2.fromOffset(position.X, position.Y)
	label.TextTransparency = 0
	label.Visible = true
	local stroke = label:FindFirstChildOfClass("UIStroke")
	if stroke then
		stroke.Transparency = 0
		TweenService:Create(stroke, TweenInfo.new(POPUP_TIME_SEC), { Transparency = 1 }):Play()
	end
	TweenService
		:Create(label, TweenInfo.new(POPUP_TIME_SEC, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			Position = UDim2.fromOffset(position.X, position.Y - POPUP_RISE_PX),
			TextTransparency = 1,
		})
		:Play()
end

local function onTap(position: Vector2)
	if not Ui.boolAttr(Attr.DataLoaded) or not takeToken() then
		return
	end
	pending = math.min(pending + 1, TAP_BATCH_MAX)
	showPopup(position)
	UiEvents.fireTapped(position)
end

local function isTapInput(input: InputObject): boolean
	local kind = input.UserInputType
	if kind == Enum.UserInputType.MouseButton1 or kind == Enum.UserInputType.Touch then
		return true
	end
	return input.KeyCode == Enum.KeyCode.ButtonR2
end

local function buildPopups()
	local screen = Ui.screen("TapPopups", 5)
	-- InputObject.Position is measured below the top-bar inset, which matches IgnoreGuiInset = false (Ui.screen).
	-- Cosmetic only: a few pixels off on odd devices is fine.
	for i = 1, POPUP_POOL do
		popups[i] = Ui.label({
			Name = `Popup{i}`,
			Size = UDim2.fromOffset(90, 36),
			AnchorPoint = Vector2.new(0.5, 1),
			TextColor3 = Ui.Theme.accent,
			Visible = false,
			Active = false,
			Parent = screen,
		})
	end
end

function TapController:Init() end

function TapController:Start()
	buildPopups() -- in Start: Ui.screen waits for PlayerGui, and Init must never yield
	local tapBatch = Remotes.getEvent("TapBatch")
	lastRefill = os.clock()

	UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
		if gameProcessed or not isTapInput(input) then
			return
		end
		local position = input.Position
		if input.KeyCode == Enum.KeyCode.ButtonR2 then
			local camera = workspace.CurrentCamera
			local size = if camera then camera.ViewportSize else Vector2.new(800, 600)
			onTap(Vector2.new(size.X / 2, size.Y / 2))
		else
			onTap(Vector2.new(position.X, position.Y))
		end
	end)

	task.spawn(function()
		while Players.LocalPlayer.Parent do
			task.wait(SEND_INTERVAL_SEC)
			if pending > 0 then
				local count = math.min(pending, TAP_BATCH_MAX)
				pending -= count
				tapBatch:FireServer(count)
			end
		end
	end)
end

return TapController
