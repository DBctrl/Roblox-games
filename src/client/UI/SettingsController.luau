--!strict
-- SettingsController: the Settings panel (toggles). Owned by systems-programmer.
-- Contract: architecture 1d #32, section 2 #16 (SetSetting), 1e (Setting* attributes), GDD 4.6, 5, 6, 10.
--
-- * Opens from the HUD gear button (UiEvents "Settings"). Six toggles: duel requests, show my own look,
--   auto-delete Commons, hide me from the donor board, Auto-Tap, Auto-Mog.
-- * A toggle fires `SetSetting(key, newValue)` and shows "..." until DataService writes the Setting* attribute
--   back (the attribute is the truth; nothing changes locally). DataService re-checks key, type and unlocks.
-- * Locked toggles cannot be pressed and say why: Auto-Tap until `AutoTapUnlocked` (Rank 3 or Auto Clicker),
--   Auto-Mog until `AutoMogUnlocked` (Rebirth 1), duel requests until `TutorialDone` (GDD 6).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Contracts = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Contracts")
local Remotes = require(Contracts:WaitForChild("Remotes"))
local Types = require(Contracts:WaitForChild("Types"))

local GameData = require(script.Parent.Util.GameData)
local Ui = require(script.Parent.Util.Ui)
local UiEvents = require(script.Parent.Util.UiEvents)

local Attr = Types.PlayerAttr
local Theme = Ui.Theme

local ROW_PX = 60
local TOGGLE_DEBOUNCE_SEC = 0.5 -- SetSetting allows 2/s, burst 5
local PENDING_TIMEOUT_SEC = 3

type Setting = {
	key: Types.SettingKey,
	attr: string,
	label: string,
	unlockAttr: string?, -- toggle is locked until this attribute is true
	lockedText: (() -> string)?,
}

local SETTINGS: { Setting } = {
	{
		key = "AutoTap",
		attr = Attr.SettingAutoTap,
		label = "Auto-Tap",
		unlockAttr = Attr.AutoTapUnlocked,
		lockedText = function()
			return `Unlocks at Rank {GameData.autoTapRank()}`
		end,
	},
	{
		key = "AutoMog",
		attr = Attr.SettingAutoMog,
		label = "Auto-Mog",
		unlockAttr = Attr.AutoMogUnlocked,
		lockedText = function()
			local n = GameData.autoMogRebirths()
			return if n == 1 then "Unlocks at your first rebirth" else `Unlocks at Rebirth {n}`
		end,
	},
	{
		key = "AutoDeleteCommons",
		attr = Attr.SettingAutoDeleteCommons,
		label = "Auto-delete Common pets",
	},
	{
		key = "DuelRequests",
		attr = Attr.SettingDuelRequests,
		label = "Duel requests",
		unlockAttr = Attr.TutorialDone,
		lockedText = function()
			return "Unlocks after the tutorial"
		end,
	},
	{
		key = "ShowOwnLook",
		attr = Attr.SettingShowOwnLook,
		label = "Show my rank look",
	},
	{
		key = "HideFromDonorBoard",
		attr = Attr.SettingHideFromDonorBoard,
		label = "Hide me from the donor board",
	},
}

type Row = { setting: Setting, toggle: TextButton, note: TextLabel, pendingUntil: number }

local SettingsController = {}

local panel: Ui.Panel? = nil
local rows: { Row } = {}
local lastToggleAt: { [string]: number } = {}

local function isLocked(setting: Setting): boolean
	local unlockAttr = setting.unlockAttr
	return unlockAttr ~= nil and not Ui.boolAttr(unlockAttr)
end

local function refreshRow(row: Row)
	local setting = row.setting
	local on = Ui.boolAttr(setting.attr)
	if isLocked(setting) then
		row.toggle.Text = "Locked"
		Ui.setEnabled(row.toggle, false)
		row.note.Text = if setting.lockedText then setting.lockedText() else ""
		row.note.Visible = true
		return
	end
	row.note.Visible = false
	if os.clock() < row.pendingUntil then
		row.toggle.Text = "..."
		Ui.setEnabled(row.toggle, false)
		return
	end
	row.toggle.Text = if on then "ON" else "OFF"
	Ui.setEnabled(row.toggle, true, if on then Theme.good else Theme.bad)
end

local function refresh()
	local p = panel
	if p == nil or not p.root.Visible then
		return
	end
	for _, row in rows do
		refreshRow(row)
	end
end

local function onToggle(setSetting: RemoteEvent, row: Row)
	local setting = row.setting
	if isLocked(setting) or not Ui.boolAttr(Attr.DataLoaded) or os.clock() < row.pendingUntil then
		return
	end
	local now = os.clock()
	if now - (lastToggleAt[setting.key] or 0) < TOGGLE_DEBOUNCE_SEC then
		return
	end
	lastToggleAt[setting.key] = now
	row.pendingUntil = now + PENDING_TIMEOUT_SEC
	refreshRow(row)
	setSetting:FireServer(setting.key, not Ui.boolAttr(setting.attr))
	-- If the server refuses (or nothing changes), the row goes back to the attribute's value.
	task.delay(PENDING_TIMEOUT_SEC, function()
		if row.pendingUntil <= os.clock() then
			refreshRow(row)
		end
	end)
end

local function build(setSetting: RemoteEvent): Ui.Panel
	local p = Ui.panel(
		"Settings",
		"Settings",
		25,
		Vector2.new(0.55, 0.75),
		Vector2.new(300, 300),
		Vector2.new(520, 560)
	)
	local list = Ui.scrollList({
		Name = "List",
		Size = UDim2.fromScale(1, 1),
		Parent = p.body,
	})
	for order, setting in SETTINGS do
		local frame = Ui.new("Frame", {
			Name = setting.key,
			LayoutOrder = order,
			BackgroundColor3 = Theme.panelLight,
			Size = UDim2.new(1, -10, 0, ROW_PX),
			Parent = list,
		}, { Ui.corner(0.2) })
		local label = Ui.label({
			Name = "Label",
			Text = setting.label,
			TextXAlignment = Enum.TextXAlignment.Left,
			Position = UDim2.fromScale(0.04, 0.08),
			Size = UDim2.fromScale(0.62, 0.5),
			Parent = frame,
		})
		Ui.textLimit(24).Parent = label
		local note = Ui.label({
			Name = "Note",
			TextXAlignment = Enum.TextXAlignment.Left,
			TextColor3 = Theme.textDim,
			Position = UDim2.fromScale(0.04, 0.58),
			Size = UDim2.fromScale(0.62, 0.34),
			Visible = false,
			Parent = frame,
		})
		Ui.textLimit(16).Parent = note
		local toggle = Ui.button({
			Name = "Toggle",
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -6, 0.5, 0),
			Size = UDim2.new(0.28, 0, 1, -12),
			Parent = frame,
		})
		Ui.textLimit(22).Parent = toggle
		local row: Row = { setting = setting, toggle = toggle, note = note, pendingUntil = 0 }
		toggle.Activated:Connect(function()
			onToggle(setSetting, row)
		end)
		table.insert(rows, row)
	end
	return p
end

function SettingsController:Init() end

function SettingsController:Start()
	local player = Players.LocalPlayer
	local p = build(Remotes.getEvent("SetSetting"))
	panel = p

	UiEvents.OpenPanel:Connect(function(name: string)
		if name == "Settings" then
			if Ui.boolAttr(Attr.DataLoaded) then
				p.root.Visible = true
				refresh()
			end
		else
			p.root.Visible = false
		end
	end)

	for _, row in rows do
		local setting = row.setting
		player:GetAttributeChangedSignal(setting.attr):Connect(function()
			row.pendingUntil = 0 -- the server answered
			if p.root.Visible then
				refreshRow(row)
			end
		end)
		local unlockAttr = setting.unlockAttr
		if unlockAttr then
			player:GetAttributeChangedSignal(unlockAttr):Connect(refresh)
		end
	end
end

return SettingsController
