--!strict
-- EggController: coin egg UI with exact odds, and the hatch result screen. Owned by systems-programmer.
-- Contract: architecture 1d #28, section 2 #6 (HatchEgg) and #19 (HatchResult), 4b, 4d; GDD 5; legal 2.1.
--
-- * Opens only from an EggStand's ProximityPrompt (the egg id comes from `MapLayout.getEggIdOf` on the prompt's
--   ancestors, 1f). A prompt only opens UI; it never buys.
-- * Before every purchase the panel lists every pet of the egg with its rarity, MP bonus, exact percentage and an
--   "Owned" tick. Percentages come straight from `EconomyConfig.EGGS[eggId].pets`, the same integer weights
--   (out of ODDS_TOTAL = 10,000) PetService rolls (4b), formatted by NumberFormat.oddsPercent. If the weights do
--   not sum to ODDS_TOTAL the panel shows no hatch button at all.
-- * Hatch x1 always; Hatch x3 from Rebirth 2 (GDD 5). Buttons fire `HatchEgg(eggId, count)` (debounced);
--   PetService re-checks the egg, coins, distance, inventory space and activity, and rolls on the server.
-- * Lean v1 (D-034): World 1 coin eggs only. A World 2 coin stand says "World 2 coming Saturday!". Robux egg
--   stands (Star, Galaxy) open Panels/RobuxEggPanel instead (T-058: odds, pity rule and counter, true odds at
--   9/10, confirmation step, restricted-account text), which this controller starts.
-- * `HatchResult` (to the hatcher only): a short "Hatching..." beat with a Skip button, then one card per pet
--   (name, rarity, bonus, NEW, auto-deleted). The 3D hatch animation is physics' CinematicController (T-045).
-- * The panel closes if the character walks away from the stand.

local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Contracts = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Contracts")
local NumberFormat = require(Contracts:WaitForChild("NumberFormat"))
local Remotes = require(Contracts:WaitForChild("Remotes"))
local Types = require(Contracts:WaitForChild("Types"))

local GameData = require(script.Parent.Util.GameData)
local PetInventory = require(script.Parent.Util.PetInventory)
local RobuxEggPanel = require(script.Parent.Panels.RobuxEggPanel)
local Ui = require(script.Parent.Util.Ui)
local UiEvents = require(script.Parent.Util.UiEvents)

local Attr = Types.PlayerAttr
local Theme = Ui.Theme

local ROW_PX = 52
local HATCH_DEBOUNCE_SEC = 1.2 -- HatchEgg allows 1/s, burst 2
local REVEAL_DELAY_SEC = 2 -- matches the ~2 s hatch animation (GDD 5); Skip shows the cards at once
local RANGE_SLACK = 8 -- studs past INTERACT_RANGE before the panel closes
local RANGE_CHECK_SEC = 0.5
local MAX_RESULT_PETS = 3

local EggController = {}

type Elements = {
	panel: Ui.Panel,
	price: TextLabel,
	list: ScrollingFrame,
	status: TextLabel,
	hatch1: TextButton,
	hatch3: TextButton,
}

type ResultUi = {
	screen: ScreenGui,
	root: Frame,
	hatching: TextLabel,
	skip: TextButton,
	cards: Frame,
	ok: TextButton,
}

local ui: Elements? = nil
local resultUi: ResultUi? = nil
local currentEgg: GameData.Egg? = nil
local lastHatchAt = 0
local revealToken = 0

-- Panel ------------------------------------------------------------------------------------------------

local function clearRows(list: ScrollingFrame)
	for _, child in list:GetChildren() do
		if child:IsA("Frame") or child:IsA("TextLabel") then
			child:Destroy()
		end
	end
end

local function addOddsRow(list: ScrollingFrame, order: number, entry: GameData.EggPet, owned: boolean)
	local pet = GameData.pet(entry.petId)
	local rarity = if pet then pet.rarity else "Common"
	local row = Ui.new("Frame", {
		Name = entry.petId,
		LayoutOrder = order,
		BackgroundColor3 = Theme.panelLight,
		Size = UDim2.new(1, -10, 0, ROW_PX),
		Parent = list,
	}, { Ui.corner(0.2), Ui.new("UIStroke", { Color = Ui.rarityColor(rarity), Thickness = 2 }) })
	local name = Ui.label({
		Name = "Name",
		Text = if pet then pet.name else entry.petId,
		TextXAlignment = Enum.TextXAlignment.Left,
		Position = UDim2.fromScale(0.03, 0.06),
		Size = UDim2.fromScale(0.5, 0.52),
		Parent = row,
	})
	Ui.textLimit(22).Parent = name
	local detail = Ui.label({
		Name = "Detail",
		Text = `{rarity}  +{if pet then string.format("%.2f", pet.bonus) else "?"} MP bonus`,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = Ui.rarityColor(rarity),
		Position = UDim2.fromScale(0.03, 0.58),
		Size = UDim2.fromScale(0.5, 0.36),
		Parent = row,
	})
	Ui.textLimit(16).Parent = detail
	local odds = Ui.label({
		Name = "Odds",
		Text = NumberFormat.oddsPercent(entry.weight),
		TextColor3 = Theme.accent,
		Position = UDim2.fromScale(0.55, 0.1),
		Size = UDim2.fromScale(0.22, 0.8),
		Parent = row,
	})
	Ui.textLimit(24).Parent = odds
	local tick = Ui.label({
		Name = "Owned",
		Text = if owned then "Owned" else "",
		TextColor3 = Theme.good,
		Position = UDim2.fromScale(0.78, 0.1),
		Size = UDim2.fromScale(0.2, 0.8),
		Parent = row,
	})
	Ui.textLimit(18).Parent = tick
end

local function addNote(list: ScrollingFrame, order: number, text: string)
	local note = Ui.label({
		Name = "Note",
		LayoutOrder = order,
		Text = text,
		TextColor3 = Theme.textDim,
		Size = UDim2.new(1, -10, 0, 44),
		Parent = list,
	})
	Ui.textLimit(20).Parent = note
end

-- Why this egg cannot be hatched from this panel right now (nil = coin egg the player may try to hatch).
local function blockedReason(egg: GameData.Egg): string?
	if egg.worldId ~= 1 then
		return "World 2 coming Saturday!"
	end
	if egg.currency ~= "Coins" then
		if not Ui.boolAttr(Attr.PaidRandomAllowed) then
			return "Robux eggs aren't available on your account"
		end
		return "Coming soon!"
	end
	if not egg.oddsValid then
		return "Odds unavailable - try again later"
	end
	return nil
end

local function refreshButtons()
	local elements = ui
	local egg = currentEgg
	if elements == nil or egg == nil or not elements.panel.root.Visible then
		return
	end
	local blocked = blockedReason(egg)
	elements.hatch1.Visible = blocked == nil
	elements.hatch3.Visible = blocked == nil
	if blocked then
		elements.status.Text = blocked
		return
	end
	local coins = Ui.numAttr(Attr.Coins, 0)
	local free = GameData.inventoryCap() - Ui.numAttr(Attr.PetCount, 0)
	local autoDelete = Ui.boolAttr(Attr.SettingAutoDeleteCommons)

	local function setHatch(button: TextButton, count: number, locked: string?)
		local cost = egg.price * count
		if locked then
			button.Text = locked
			Ui.setEnabled(button, false)
		elseif coins < cost then
			button.Text = `Hatch x{count}: need {NumberFormat.abbreviate(cost)}`
			Ui.setEnabled(button, false)
		else
			button.Text = `Hatch x{count}: {NumberFormat.abbreviate(cost)} Coins`
			Ui.setEnabled(button, true)
		end
	end
	setHatch(elements.hatch1, 1, nil)
	local x3Rebirths = GameData.hatchThreeRebirths()
	local x3Locked = if Ui.numAttr(Attr.Rebirths, 0) < x3Rebirths then `x3 at Rebirth {x3Rebirths}` else nil
	setHatch(elements.hatch3, 3, x3Locked)

	if free <= 0 and not autoDelete then
		elements.status.Text = "Inventory full: delete some pets first"
	else
		elements.status.Text = `Pets: {math.floor(Ui.numAttr(Attr.PetCount, 0))}/{GameData.inventoryCap()}`
	end
end

local function render()
	local elements = ui
	local egg = currentEgg
	if elements == nil or egg == nil then
		return
	end
	elements.panel.title.Text = egg.name
	elements.price.Text = if egg.currency == "Coins"
		then `{NumberFormat.abbreviate(egg.price)} Coins per hatch`
		else ""
	clearRows(elements.list)
	local hideOdds = egg.currency ~= "Coins" and not Ui.boolAttr(Attr.PaidRandomAllowed)
	if not hideOdds then
		local owned = PetInventory.ownedIds()
		for order, entry in egg.pets do
			addOddsRow(elements.list, order, entry, owned[entry.petId] == true)
		end
		addNote(elements.list, #egg.pets + 1, "Every hatch uses these odds.")
	end
	refreshButtons()
end

local function close()
	local elements = ui
	if elements then
		elements.panel.root.Visible = false
	end
	currentEgg = nil
end

local function open(eggId: string)
	if RobuxEggPanel.handles(eggId) then
		UiEvents.fireOpenRobuxEgg(eggId) -- Robux eggs have their own screen (T-058)
		return
	end
	local elements = ui
	local egg = GameData.egg(eggId)
	if elements == nil or egg == nil or not Ui.boolAttr(Attr.DataLoaded) then
		return
	end
	UiEvents.fireOpenPanel("Eggs") -- closes every other panel
	currentEgg = egg
	elements.panel.root.Visible = true
	render()
end

local function onHatch(hatchEgg: RemoteEvent, count: number)
	local egg = currentEgg
	if egg == nil or blockedReason(egg) ~= nil then
		return
	end
	if count == 3 and Ui.numAttr(Attr.Rebirths, 0) < GameData.hatchThreeRebirths() then
		return
	end
	if Ui.numAttr(Attr.Coins, 0) < egg.price * count then
		return
	end
	local now = os.clock()
	if now - lastHatchAt < HATCH_DEBOUNCE_SEC then
		return
	end
	lastHatchAt = now
	hatchEgg:FireServer(egg.id, count)
end

local function build(hatchEgg: RemoteEvent): Elements
	local panel =
		Ui.panel("EggShop", "Egg", 20, Vector2.new(0.62, 0.8), Vector2.new(310, 330), Vector2.new(580, 600))
	local price = Ui.label({
		Name = "Price",
		TextColor3 = Theme.coins,
		Size = UDim2.fromScale(1, 0.08),
		Parent = panel.body,
	})
	Ui.textLimit(22).Parent = price
	local list = Ui.scrollList({
		Name = "Odds",
		Position = UDim2.fromScale(0, 0.09),
		Size = UDim2.fromScale(1, 0.62),
		Parent = panel.body,
	}, 4)
	local status = Ui.label({
		Name = "Status",
		TextColor3 = Theme.textDim,
		Position = UDim2.fromScale(0, 0.72),
		Size = UDim2.fromScale(1, 0.08),
		Parent = panel.body,
	})
	Ui.textLimit(18).Parent = status
	local function hatchButton(name: string, x: number, count: number): TextButton
		local button = Ui.button({
			Name = name,
			AnchorPoint = Vector2.new(x, 1),
			Position = UDim2.fromScale(x, 1),
			Size = UDim2.fromScale(0.48, 0.17),
			Parent = panel.body,
		})
		Ui.textLimit(22).Parent = button
		button.Activated:Connect(function()
			onHatch(hatchEgg, count)
		end)
		return button
	end
	local hatch1 = hatchButton("Hatch1", 0, 1)
	local hatch3 = hatchButton("Hatch3", 1, 3)
	panel.close.Activated:Connect(close)
	return { panel = panel, price = price, list = list, status = status, hatch1 = hatch1, hatch3 = hatch3 }
end

-- Hatch result -----------------------------------------------------------------------------------------

local function buildResult(): ResultUi
	local screen = Ui.screen("HatchResult", 30)
	local root = Ui.new("Frame", {
		Name = "HatchResult",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(0.7, 0.55),
		BackgroundColor3 = Theme.panel,
		BackgroundTransparency = 0.1,
		Visible = false,
		Parent = screen,
	}, { Ui.corner(0.06), Ui.stroke(3), Ui.sizeLimit(300, 240, 640, 420) })
	local hatching = Ui.label({
		Name = "Hatching",
		Text = "Hatching...",
		TextColor3 = Theme.accent,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.fromScale(0.5, 0.25),
		Size = UDim2.fromScale(0.8, 0.25),
		Parent = root,
	})
	Ui.textLimit(44).Parent = hatching
	local cards = Ui.new("Frame", {
		Name = "Cards",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.fromScale(0.5, 0.06),
		Size = UDim2.fromScale(0.94, 0.66),
		Visible = false,
		Parent = root,
	}, {
		Ui.new("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal,
			HorizontalAlignment = Enum.HorizontalAlignment.Center,
			VerticalAlignment = Enum.VerticalAlignment.Center,
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0.02, 0),
		}),
	})
	local skip = Ui.button({
		Name = "Skip",
		Text = "Skip",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -10),
		Size = UDim2.fromScale(0.36, 0.18),
		Parent = root,
	})
	Ui.textLimit(26).Parent = skip
	local ok = Ui.button({
		Name = "Ok",
		Text = "Nice!",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -10),
		Size = UDim2.fromScale(0.36, 0.18),
		BackgroundColor3 = Theme.good,
		Visible = false,
		Parent = root,
	})
	Ui.textLimit(26).Parent = ok
	ok.Activated:Connect(function()
		root.Visible = false
	end)
	return { screen = screen, root = root, hatching = hatching, skip = skip, cards = cards, ok = ok }
end

local function addCard(cards: Frame, order: number, pet: Types.HatchedPet)
	local info = GameData.pet(pet.petId)
	local rarity = if info then info.rarity else pet.rarity
	local card = Ui.new("Frame", {
		Name = `Card{order}`,
		LayoutOrder = order,
		BackgroundColor3 = Theme.panelLight,
		Size = UDim2.fromScale(0.3, 1),
		Parent = cards,
	}, { Ui.corner(0.1), Ui.new("UIStroke", { Color = Ui.rarityColor(rarity), Thickness = 3 }) })
	local function cardLine(text: string, y: number, h: number, color: Color3, maxText: number)
		local label = Ui.label({
			Text = text,
			TextColor3 = color,
			Position = UDim2.fromScale(0.05, y),
			Size = UDim2.fromScale(0.9, h),
			Parent = card,
		})
		Ui.textLimit(maxText).Parent = label
	end
	cardLine(if pet.isNew then "NEW!" else "", 0.04, 0.16, Theme.accent, 22)
	cardLine(if info then info.name else pet.petId, 0.22, 0.26, Theme.text, 26)
	cardLine(rarity, 0.5, 0.16, Ui.rarityColor(rarity), 20)
	cardLine(if info then `+{string.format("%.2f", info.bonus)} MP` else "", 0.66, 0.14, Theme.good, 18)
	cardLine(if pet.autoDeleted then "Auto-deleted" else "", 0.82, 0.14, Theme.bad, 16)
end

local function reveal(result: ResultUi)
	result.hatching.Visible = false
	result.skip.Visible = false
	result.cards.Visible = true
	result.ok.Visible = true
end

-- Validates the server payload shape before drawing anything.
local function validPets(payload: any): { Types.HatchedPet }?
	if type(payload) ~= "table" or type(payload.pets) ~= "table" then
		return nil
	end
	local out: { Types.HatchedPet } = {}
	for _, pet in ipairs(payload.pets) do
		if #out >= MAX_RESULT_PETS then
			break
		end
		if type(pet) == "table" and type(pet.petId) == "string" and #pet.petId <= 40 then
			table.insert(
				out,
				{
					uid = if type(pet.uid) == "string" then pet.uid else nil,
					petId = pet.petId,
					rarity = if type(pet.rarity) == "string" then pet.rarity else "Common",
					isNew = pet.isNew == true,
					autoDeleted = pet.autoDeleted == true,
					pity = pet.pity == true,
				} :: any
			)
		end
	end
	return if #out > 0 then out else nil
end

local function onHatchResult(payload: any)
	local result = resultUi
	local pets = validPets(payload)
	if result == nil or pets == nil then
		return
	end
	for _, child in result.cards:GetChildren() do
		if child:IsA("Frame") then
			child:Destroy()
		end
	end
	for order, pet in pets do
		addCard(result.cards, order, pet)
		if not pet.autoDeleted then
			PetInventory.noteHatched(pet.petId)
		end
	end
	result.cards.Visible = false
	result.ok.Visible = false
	result.hatching.Visible = true
	result.skip.Visible = true
	result.root.Visible = true
	revealToken += 1
	local token = revealToken
	task.delay(REVEAL_DELAY_SEC, function()
		if token == revealToken then
			reveal(result)
		end
	end)
	render() -- refresh "Owned" ticks and buttons if the egg panel is still open
end

-- Lifecycle ------------------------------------------------------------------------------------------

function EggController:Init() end

function EggController:Start()
	local player = Players.LocalPlayer
	local elements = build(Remotes.getEvent("HatchEgg"))
	ui = elements
	local result = buildResult()
	resultUi = result
	task.spawn(RobuxEggPanel.start) -- its own panel; waits for the RequestPurchase remote
	result.skip.Activated:Connect(function()
		revealToken += 1
		reveal(result)
	end)

	ProximityPromptService.PromptTriggered:Connect(function(prompt: ProximityPrompt, who: Player)
		if who ~= player then
			return
		end
		local eggId = GameData.eggIdOfPrompt(prompt)
		if eggId then
			open(eggId)
		end
	end)
	UiEvents.OpenPanel:Connect(function(name: string)
		if name ~= "Eggs" then
			close()
		end
	end)
	Remotes.getEvent("HatchResult").OnClientEvent:Connect(onHatchResult)

	for _, name in
		{
			Attr.Coins,
			Attr.Rebirths,
			Attr.PetCount,
			Attr.SettingAutoDeleteCommons,
			Attr.PaidRandomAllowed,
		}
	do
		player:GetAttributeChangedSignal(name):Connect(refreshButtons)
	end
	PetInventory.onChanged(function()
		if elements.panel.root.Visible then
			render()
		end
	end)

	-- Close the panel when the character walks away from the stand.
	task.spawn(function()
		while player.Parent do
			task.wait(RANGE_CHECK_SEC)
			local egg = currentEgg
			if egg and elements.panel.root.Visible then
				local character = player.Character
				local root = character and character:FindFirstChild("HumanoidRootPart")
				local standPos = GameData.eggStandPosition(egg.id)
				if root and root:IsA("BasePart") and standPos then
					if (root.Position - standPos).Magnitude > GameData.interactRange() + RANGE_SLACK then
						close()
					end
				end
			end
		end
	end)
end

return EggController
