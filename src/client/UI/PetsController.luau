--!strict
-- PetsController: pet inventory grid, equip / unequip, equip best and multi-delete. Owned by systems-programmer.
-- Contract: architecture 1d #29, section 2 #7 (EquipPet) and #8 (DeletePets), 1e (PetCount, PetSlots), GDD 5.
--
-- * Opens from the HUD "Pets" button (UiEvents "Pets"). Header shows "Pets 12/60" and "Equipped 2/3"
--   (PetSlots). The grid holds up to INVENTORY_HARD_CAP cells; columns follow the panel width, so it works from
--   a phone (3-4 columns, cells >= 64 px) to a desktop (up to 7).
-- * Tap a pet: equip or unequip it (`EquipPet(uid, equip)`); with every slot full it says so instead.
--   "Equip best": unequips, then equips the highest-bonus pets up to PetSlots (EquipPet calls spaced to stay
--   under the 8/s limit). "Delete": select mode; tap pets to mark them, then "Delete N" asks to confirm and fires
--   one `DeletePets(uids)` (max 60). PetService re-checks ownership, slots, duplicates and unequips first.
-- * Pet uids come from the `PetInventory` attribute (Util/PetInventory, Contract request CR-S2a). Until PetService
--   writes it, the panel says the inventory is syncing and offers no actions.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Contracts = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Contracts")
local Remotes = require(Contracts:WaitForChild("Remotes"))
local Types = require(Contracts:WaitForChild("Types"))

local GameData = require(script.Parent.Util.GameData)
local PetInventory = require(script.Parent.Util.PetInventory)
local Ui = require(script.Parent.Util.Ui)
local UiEvents = require(script.Parent.Util.UiEvents)

local Attr = Types.PlayerAttr
local Theme = Ui.Theme

local MIN_CELL_PX = 64
local MAX_COLUMNS = 7
local CELL_PAD_PX = 6
local EQUIP_DEBOUNCE_SEC = 0.15
local EQUIP_SPACING_SEC = 0.15 -- EquipPet allows 8/s, burst 10
local DELETE_MAX = 60 -- DeletePets accepts 1..60 uids
local DELETE_DEBOUNCE_SEC = 1.2 -- DeletePets allows 1/s
local DEFAULT_SLOTS = 3

local PetsController = {}

type Elements = {
	panel: Ui.Panel,
	header: TextLabel,
	status: TextLabel,
	grid: ScrollingFrame,
	layout: UIGridLayout,
	equipBest: TextButton,
	deleteMode: TextButton,
	confirm: Frame,
	confirmText: TextLabel,
	confirmYes: TextButton,
	confirmNo: TextButton,
}

local ui: Elements? = nil
local deleting = false
local selected: { [string]: boolean } = {}
local lastEquipAt = 0
local lastDeleteAt = 0
local equipBestRunning = false

local function slots(): number
	return math.floor(Ui.numAttr(Attr.PetSlots, DEFAULT_SLOTS))
end

local function bonusOf(petId: string): number
	local pet = GameData.pet(petId)
	return if pet then pet.bonus else 0
end

local function selectedCount(): number
	local n = 0
	for _ in selected do
		n += 1
	end
	return n
end

-- Grid ---------------------------------------------------------------------------------------------------

local function sizeGrid(elements: Elements)
	local width = elements.grid.AbsoluteSize.X - 8
	if width <= 0 then
		return
	end
	local columns = math.clamp(math.floor(width / (MIN_CELL_PX + 30)), 3, MAX_COLUMNS)
	local cell = math.max(MIN_CELL_PX, math.floor((width - CELL_PAD_PX * (columns + 1)) / columns))
	elements.layout.CellSize = UDim2.fromOffset(cell, math.floor(cell * 1.15))
end

local function onCellPressed(equipPet: RemoteEvent, entry: PetInventory.Entry)
	if deleting then
		if selected[entry.uid] then
			selected[entry.uid] = nil
		elseif selectedCount() < DELETE_MAX then
			selected[entry.uid] = true
		end
		return
	end
	local now = os.clock()
	if now - lastEquipAt < EQUIP_DEBOUNCE_SEC or equipBestRunning then
		return
	end
	local entries = PetInventory.entries() or {}
	local equipped = 0
	for _, other in entries do
		if other.equipped then
			equipped += 1
		end
	end
	local elements = ui
	if not entry.equipped and equipped >= slots() then
		if elements then
			elements.status.Text = `All {slots()} slots are full. Unequip a pet first.`
		end
		return
	end
	lastEquipAt = now
	equipPet:FireServer(entry.uid, not entry.equipped)
end

local render: () -> ()

local function addCell(elements: Elements, equipPet: RemoteEvent, order: number, entry: PetInventory.Entry)
	local pet = GameData.pet(entry.petId)
	local rarity = if pet then pet.rarity else "Common"
	local marked = deleting and selected[entry.uid] == true
	local cell = Ui.new("TextButton", {
		Name = `Pet{entry.uid}`,
		LayoutOrder = order,
		Text = "",
		AutoButtonColor = true,
		BackgroundColor3 = if marked
			then Theme.bad
			elseif entry.equipped then Theme.good
			else Theme.panelLight,
		Parent = elements.grid,
	}, { Ui.corner(0.12), Ui.new("UIStroke", { Color = Ui.rarityColor(rarity), Thickness = 3 }) })
	local function line(text: string, y: number, h: number, color: Color3, maxText: number)
		local label = Ui.label({
			Text = text,
			TextColor3 = color,
			Position = UDim2.fromScale(0.05, y),
			Size = UDim2.fromScale(0.9, h),
			Parent = cell,
		})
		Ui.textLimit(maxText).Parent = label
	end
	line(if pet then pet.name else entry.petId, 0.08, 0.4, Theme.text, 18)
	line(if pet then `+{string.format("%.2f", pet.bonus)}` else "", 0.5, 0.22, Theme.accent, 16)
	line(if marked then "DELETE" elseif entry.equipped then "Equipped" else rarity, 0.74, 0.2, Theme.text, 14)
	cell.Activated:Connect(function()
		onCellPressed(equipPet, entry)
		render()
	end)
end

local equipRemote: RemoteEvent? = nil

render = function()
	local elements = ui
	local equipPet = equipRemote
	if elements == nil or equipPet == nil or not elements.panel.root.Visible then
		return
	end
	for _, child in elements.grid:GetChildren() do
		if child:IsA("GuiButton") then
			child:Destroy()
		end
	end
	local entries = PetInventory.entries()
	local count = math.floor(Ui.numAttr(Attr.PetCount, 0))
	if entries == nil then
		elements.header.Text = `Pets {count}/{GameData.inventoryCap()}`
		elements.status.Text = "Syncing your pets..."
		elements.equipBest.Visible = false
		elements.deleteMode.Visible = false
		return
	end
	elements.equipBest.Visible = not deleting
	elements.deleteMode.Visible = true

	-- Drop selections for pets that are gone (deleted or traded away by the server).
	local present: { [string]: boolean } = {}
	local equipped = 0
	for _, entry in entries do
		present[entry.uid] = true
		if entry.equipped then
			equipped += 1
		end
	end
	for uid in selected do
		if not present[uid] then
			selected[uid] = nil
		end
	end

	table.sort(entries, function(a, b)
		if a.equipped ~= b.equipped then
			return a.equipped
		end
		local ba, bb = bonusOf(a.petId), bonusOf(b.petId)
		if ba ~= bb then
			return ba > bb
		end
		return a.uid < b.uid
	end)
	for order, entry in entries do
		addCell(elements, equipPet, order, entry)
	end

	elements.header.Text = `Pets {#entries}/{GameData.inventoryCap()}   Equipped {equipped}/{slots()}`
	local picked = selectedCount()
	if deleting then
		elements.deleteMode.Text = if picked > 0 then `Delete {picked}` else "Cancel"
		Ui.setEnabled(elements.deleteMode, true, if picked > 0 then Theme.bad else Theme.panelLight)
		elements.status.Text = "Tap pets to mark them for deleting."
	else
		elements.deleteMode.Text = "Delete pets"
		Ui.setEnabled(elements.deleteMode, #entries > 0, Theme.panelLight)
		elements.status.Text = if #entries == 0
			then "No pets yet: hatch an egg!"
			else "Tap a pet to equip it."
	end
end

-- Equip best ------------------------------------------------------------------------------------------

local function equipBest(equipPet: RemoteEvent)
	if equipBestRunning or deleting then
		return
	end
	local entries = PetInventory.entries()
	if entries == nil or #entries == 0 then
		return
	end
	table.sort(entries, function(a, b)
		local ba, bb = bonusOf(a.petId), bonusOf(b.petId)
		if ba ~= bb then
			return ba > bb
		end
		return a.equipped and not b.equipped -- keep already-equipped pets on ties
	end)
	local best: { [string]: boolean } = {}
	for i = 1, math.min(slots(), #entries) do
		best[entries[i].uid] = true
	end
	local calls: { { uid: string, equip: boolean } } = {}
	for _, entry in entries do
		if entry.equipped and not best[entry.uid] then
			table.insert(calls, { uid = entry.uid, equip = false }) -- free the slots first
		end
	end
	for _, entry in entries do
		if best[entry.uid] and not entry.equipped then
			table.insert(calls, { uid = entry.uid, equip = true })
		end
	end
	if #calls == 0 then
		return
	end
	equipBestRunning = true
	task.spawn(function()
		for _, call in calls do
			equipPet:FireServer(call.uid, call.equip)
			task.wait(EQUIP_SPACING_SEC)
		end
		equipBestRunning = false
	end)
end

-- Delete ----------------------------------------------------------------------------------------------

local function showConfirm(elements: Elements)
	local picked = selectedCount()
	if picked == 0 then
		deleting = false
		render()
		return
	end
	elements.confirmText.Text = `Delete {picked} pet{if picked == 1 then "" else "s"}? This can't be undone.`
	elements.confirm.Visible = true
end

local function confirmDelete(deletePets: RemoteEvent, elements: Elements)
	elements.confirm.Visible = false
	local now = os.clock()
	if now - lastDeleteAt < DELETE_DEBOUNCE_SEC then
		return
	end
	local uids = {}
	for uid in selected do
		if #uids >= DELETE_MAX then
			break
		end
		table.insert(uids, uid)
	end
	if #uids == 0 then
		return
	end
	lastDeleteAt = now
	deletePets:FireServer(uids)
	table.clear(selected)
	deleting = false
	render()
end

local function build(deletePets: RemoteEvent): Elements
	local panel =
		Ui.panel("Pets", "My Pets", 20, Vector2.new(0.8, 0.82), Vector2.new(310, 340), Vector2.new(820, 640))
	local header = Ui.label({
		Name = "Header",
		Size = UDim2.fromScale(1, 0.07),
		TextColor3 = Theme.accent,
		Parent = panel.body,
	})
	Ui.textLimit(22).Parent = header
	local grid = Ui.new("ScrollingFrame", {
		Name = "Grid",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 6,
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		Position = UDim2.fromScale(0, 0.08),
		Size = UDim2.fromScale(1, 0.66),
		Parent = panel.body,
	})
	local layout = Ui.new("UIGridLayout", {
		CellPadding = UDim2.fromOffset(CELL_PAD_PX, CELL_PAD_PX),
		CellSize = UDim2.fromOffset(80, 92),
		SortOrder = Enum.SortOrder.LayoutOrder,
		HorizontalAlignment = Enum.HorizontalAlignment.Center,
		Parent = grid,
	})
	local status = Ui.label({
		Name = "Status",
		TextColor3 = Theme.textDim,
		Position = UDim2.fromScale(0, 0.75),
		Size = UDim2.fromScale(1, 0.07),
		Parent = panel.body,
	})
	Ui.textLimit(18).Parent = status
	local function bottomButton(name: string, x: number, text: string): TextButton
		local button = Ui.button({
			Name = name,
			Text = text,
			AnchorPoint = Vector2.new(x, 1),
			Position = UDim2.fromScale(x, 1),
			Size = UDim2.fromScale(0.48, 0.15),
			Parent = panel.body,
		})
		Ui.textLimit(24).Parent = button
		return button
	end
	local equipBestButton = bottomButton("EquipBest", 0, "Equip best")
	equipBestButton.BackgroundColor3 = Theme.good
	local deleteMode = bottomButton("DeleteMode", 1, "Delete pets")

	-- Delete confirm dialog over the panel.
	local confirm = Ui.new("Frame", {
		Name = "Confirm",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(0.8, 0.4),
		BackgroundColor3 = Theme.panel,
		ZIndex = 5,
		Visible = false,
		Parent = panel.root,
	}, { Ui.corner(0.08), Ui.stroke(3), Ui.sizeLimit(260, 150, 520, 260) })
	local confirmText = Ui.label({
		Name = "Text",
		ZIndex = 6,
		Position = UDim2.fromScale(0.05, 0.08),
		Size = UDim2.fromScale(0.9, 0.44),
		Parent = confirm,
	})
	Ui.textLimit(24).Parent = confirmText
	local function confirmButton(name: string, x: number, text: string, color: Color3): TextButton
		local button = Ui.button({
			Name = name,
			Text = text,
			ZIndex = 6,
			AnchorPoint = Vector2.new(x, 1),
			Position = UDim2.new(x, if x == 0 then 10 else -10, 1, -10),
			Size = UDim2.fromScale(0.42, 0.34),
			BackgroundColor3 = color,
			Parent = confirm,
		})
		Ui.textLimit(24).Parent = button
		return button
	end
	local confirmYes = confirmButton("Yes", 0, "Delete", Theme.bad)
	local confirmNo = confirmButton("No", 1, "Keep", Theme.panelLight)

	local elements: Elements = {
		panel = panel,
		header = header,
		status = status,
		grid = grid,
		layout = layout,
		equipBest = equipBestButton,
		deleteMode = deleteMode,
		confirm = confirm,
		confirmText = confirmText,
		confirmYes = confirmYes,
		confirmNo = confirmNo,
	}
	deleteMode.Activated:Connect(function()
		if deleting then
			showConfirm(elements) -- with nothing marked this just leaves delete mode
		else
			deleting = true
			table.clear(selected)
			render()
		end
	end)
	confirmYes.Activated:Connect(function()
		confirmDelete(deletePets, elements)
	end)
	confirmNo.Activated:Connect(function()
		confirm.Visible = false
	end)
	panel.close.Activated:Connect(function()
		deleting = false
		table.clear(selected)
		confirm.Visible = false
	end)
	grid:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		sizeGrid(elements)
	end)
	return elements
end

function PetsController:Init() end

function PetsController:Start()
	local player = Players.LocalPlayer
	local equipPet = Remotes.getEvent("EquipPet")
	equipRemote = equipPet
	local elements = build(Remotes.getEvent("DeletePets"))
	ui = elements
	elements.equipBest.Activated:Connect(function()
		equipBest(equipPet)
	end)

	UiEvents.OpenPanel:Connect(function(name: string)
		if name == "Pets" then
			if Ui.boolAttr(Attr.DataLoaded) then
				elements.panel.root.Visible = true
				sizeGrid(elements)
				render()
			end
		else
			elements.panel.root.Visible = false
			elements.confirm.Visible = false
			deleting = false
			table.clear(selected)
		end
	end)
	PetInventory.onChanged(render)
	player:GetAttributeChangedSignal(Attr.PetSlots):Connect(render)
end

return PetsController
