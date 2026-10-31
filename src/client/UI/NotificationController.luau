--!strict
-- NotificationController: `Notify` toasts (max 3 on screen) and server banners. Owned by systems-programmer.
-- Contract: architecture 1d #33, section 2 #17 (Types.NotifyPayload).
--
-- * Text is built by the server and never echoes client strings; this file still type-checks the payload,
--   caps the text length and ignores anything malformed.
-- * Toasts (Info, Success, Error): stacked on the left, newest at the bottom; a 4th toast removes the oldest.
-- * Banners (Banner, Donation): one at a time across the top; later banners queue (max 5 waiting, extras dropped).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Contracts = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Contracts")
local Remotes = require(Contracts:WaitForChild("Remotes"))
local Types = require(Contracts:WaitForChild("Types"))

local Ui = require(script.Parent.Util.Ui)

local Theme = Ui.Theme

local MAX_TOASTS = 3
local MAX_QUEUED_BANNERS = 5
local MAX_TEXT_LEN = 200
local DEFAULT_TOAST_SEC = 3
local DEFAULT_BANNER_SEC = 4
local MIN_SEC, MAX_SEC = 1, 10

local KIND_COLORS: { [Types.NotifyKind]: Color3 } = {
	Info = Theme.panelLight,
	Success = Theme.good,
	Error = Theme.bad,
	Banner = Theme.accent,
	Donation = Theme.coins,
}

local NotificationController = {}

local toastList: Frame? = nil
local bannerLabel: TextLabel? = nil
local toasts: { Frame } = {}
local bannerQueue: { Types.NotifyPayload } = {}
local bannerBusy = false
local toastCounter = 0

local function build()
	local screen = Ui.screen("Notifications", 30)
	toastList = Ui.new("Frame", {
		Name = "Toasts",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 8, 0.45, 0),
		Size = UDim2.fromScale(0.32, 0.36),
		Active = false,
		Parent = screen,
	}, {
		Ui.sizeLimit(200, 120, 380, 260),
		Ui.new("UIListLayout", {
			FillDirection = Enum.FillDirection.Vertical,
			VerticalAlignment = Enum.VerticalAlignment.Bottom,
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0.03, 0),
		}),
	})
	local banner = Ui.label({
		Name = "Banner",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.fromScale(0.5, 0.25),
		Size = UDim2.fromScale(0.7, 0.07),
		BackgroundTransparency = 0.1,
		BackgroundColor3 = Theme.panel,
		TextColor3 = Theme.accent,
		Visible = false,
		Parent = screen,
	})
	Ui.corner(0.3).Parent = banner
	Ui.sizeLimit(240, 36, 700, 64).Parent = banner
	Ui.textLimit(30).Parent = banner
	bannerLabel = banner
end

local function duration(payload: Types.NotifyPayload, default: number): number
	local seconds = payload.durationSec
	if type(seconds) ~= "number" or seconds ~= seconds then
		return default
	end
	return math.clamp(seconds, MIN_SEC, MAX_SEC)
end

local function removeToast(toast: Frame)
	local index = table.find(toasts, toast)
	if index then
		table.remove(toasts, index)
	end
	toast:Destroy()
end

local function showToast(payload: Types.NotifyPayload)
	local list = toastList
	if list == nil then
		return
	end
	while #toasts >= MAX_TOASTS do
		removeToast(toasts[1])
	end
	toastCounter += 1
	local toast = Ui.new("Frame", {
		Name = "Toast",
		LayoutOrder = toastCounter,
		Size = UDim2.fromScale(1, 0.3),
		BackgroundColor3 = KIND_COLORS[payload.kind] or Theme.panelLight,
		BackgroundTransparency = 0.1,
		Parent = list,
	}, { Ui.corner(0.3), Ui.stroke() })
	local label = Ui.label({
		Text = payload.text,
		Size = UDim2.fromScale(0.92, 0.8),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Parent = toast,
	})
	Ui.textLimit(22).Parent = label
	table.insert(toasts, toast)
	task.delay(duration(payload, DEFAULT_TOAST_SEC), function()
		if toast.Parent then
			removeToast(toast)
		end
	end)
end

local function runBanners()
	local banner = bannerLabel
	if bannerBusy or banner == nil then
		return
	end
	bannerBusy = true
	while #bannerQueue > 0 do
		local payload = table.remove(bannerQueue, 1) :: Types.NotifyPayload
		banner.Text = payload.text
		banner.TextColor3 = KIND_COLORS[payload.kind] or Theme.accent
		banner.TextTransparency = 1
		banner.Visible = true
		TweenService:Create(banner, TweenInfo.new(0.25), { TextTransparency = 0 }):Play()
		task.wait(duration(payload, DEFAULT_BANNER_SEC))
		banner.Visible = false
	end
	bannerBusy = false
end

-- Returns a clean payload, or nil if the server sent something malformed.
local function parse(raw: any): Types.NotifyPayload?
	if type(raw) ~= "table" or type(raw.text) ~= "string" or KIND_COLORS[raw.kind] == nil then
		return nil
	end
	local text = string.sub(raw.text, 1, MAX_TEXT_LEN)
	if text == "" then
		return nil
	end
	return {
		kind = raw.kind,
		text = text,
		durationSec = if type(raw.durationSec) == "number" then raw.durationSec else nil,
	}
end

local function onNotify(raw: any)
	local payload = parse(raw)
	if payload == nil then
		return
	end
	if payload.kind == "Banner" or payload.kind == "Donation" then
		if #bannerQueue < MAX_QUEUED_BANNERS then
			table.insert(bannerQueue, payload)
		end
		task.spawn(runBanners)
	else
		showToast(payload)
	end
end

function NotificationController:Init() end

function NotificationController:Start()
	build()
	Remotes.getEvent("Notify").OnClientEvent:Connect(onNotify)
end

return NotificationController
