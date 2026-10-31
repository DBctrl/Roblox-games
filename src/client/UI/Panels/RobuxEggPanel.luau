--!strict
-- RobuxEggPanel: the Robux egg screen (Star Egg, Galaxy Egg) with exact odds, the pity rule and counter, true odds
-- at 9/10, a confirmation step, and the restricted-account text (helper, not a controller: EggController starts
-- it). Owned by systems-programmer (T-058). Contract: architecture 2 #13, 4b, 4d, 4f; GDD 5 and 8f; legal 2.1,
-- 2.2, 2.5, RC-4, RC-5.
--
-- * Opens from a Robux EggStand prompt (EggController routes it here) or the shop's "Odds Info" button. Opening
--   never buys.
-- * Odds come from EconomyConfig.EGGS[eggId].pets through GameData, the same integer weights PetService rolls.
--   The pity rule is the lawyer's exact `ProductCatalog.PITY_RULE` (T-071, D-056), the same words as the product
--   listing. The counter "Pity: 7/10" is the server's Pity<Egg> attribute (saved per egg).
-- * True odds (legal 2.2): when the counter is 9/10 the table shows the real next-hatch odds (the Legendary and
--   Mythic pets at 90% / 10%, every other pet 0%) instead of the base table, on this screen and in the
--   confirmation step. A 3-pack lists the odds for each of its 3 hatches.
-- * Buy x1 / Buy x3 open the confirmation step (odds and pity again, then "Buy" fires RequestPurchase(key) once).
--   MonetizationService re-checks FirstWin, PaidRandomAllowed, inventory space and the product id; the Roblox
--   prompt comes from the server. While product ids are placeholders (canSell false, "NoProductId") the odds are
--   still shown and both buttons say "Coming soon" and send nothing.
-- * Restricted accounts (PaidRandomAllowed false, fail closed): "Robux eggs aren't available on your account", the
--   stated fixed pet ("If a purchase still goes through, you get Nebula Fox (no random roll). A 3-pack gives
--   3 Nebula Fox."), and no buy button (GDD 5, legal RC-4).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Contracts = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Contracts")
local NumberFormat = require(Contracts:WaitForChild("NumberFormat"))
local ProductCatalog = require(Contracts:WaitForChild("ProductCatalog"))
local Remotes = require(Contracts:WaitForChild("Remotes"))
local Types = require(Contracts:WaitForChild("Types"))

local GameData = require(script.Parent.Parent.Util.GameData)
local PetInventory = require(script.Parent.Parent.Util.PetInventory)
local Ui = require(script.Parent.Parent.Util.Ui)
local UiEvents = require(script.Parent.Parent.Util.UiEvents)

local Attr = Types.PlayerAttr
local Theme = Ui.Theme

local PANEL_NAME = "RobuxEgg"
local ROW_PX = 52
local BUY_DEBOUNCE_SEC = 2.5 -- RequestPurchase allows 0.5/s, burst 2
local DEFAULT_PITY_AT = 10
local PITY_RULE = ProductCatalog.PITY_RULE -- lawyer's exact wording (T-071); never a local copy
local PACK_NOTE = "Each of the 3 hatches uses these odds. Pity can trigger inside the pack."
local RESTRICTED_TEXT = "Robux eggs aren't available on your account"

-- Robux egg id -> its 1-pack and 3-pack product keys and its pity attribute.
local EGG_PRODUCTS: { [string]: { one: Types.ProductKey, three: Types.ProductKey, pityAttr: string } } = {
	StarEgg = { one = "StarEgg1", three = "StarEgg3", pityAttr = Attr.PityStarEgg },
	GalaxyEgg = { one = "GalaxyEgg1", three = "GalaxyEgg3", pityAttr = Attr.PityGalaxyEgg },
}

type Odds = { { petId: string, weight: number } } -- weights out of ODDS_TOTAL, in the egg's order

type Elements = {
	panel: Ui.Panel,
	pity: TextLabel,
	rule: TextLabel,
	list: ScrollingFrame,
	status: TextLabel,
	buy1: TextButton,
	buy3: TextButton,
}

type Confirm = {
	screen: ScreenGui,
	root: Frame,
	title: TextLabel,
	body: TextLabel,
	buy: TextButton,
	back: TextButton,
}

local RobuxEggPanel = {}

local ui: Elements? = nil
local confirmUi: Confirm? = nil
local currentEggId: string? = nil
local confirmKey: Types.ProductKey? = nil
local lastBuyAt = 0

-- Odds maths (display of the server's rule) --------------------------------------------------------------

local function pityAt(eggId: string): number
	local egg = GameData.egg(eggId)
	return if egg and egg.pityAt then egg.pityAt else DEFAULT_PITY_AT
end

local function pityCount(eggId: string): number
	local info = EGG_PRODUCTS[eggId]
	return if info then math.floor(Ui.numAttr(info.pityAttr, 0)) else 0
end

local function rarityOf(petId: string): string
	local pet = GameData.pet(petId)
	return if pet then pet.rarity else "Common"
end

local function baseOdds(egg: GameData.Egg): Odds
	local out: Odds = {}
	for _, row in egg.pets do
		table.insert(out, { petId = row.petId, weight = row.weight })
	end
	return out
end

-- The forced pity roll: Legendary pets share 90% and Mythic pets 10% (in proportion to their base weights);
-- every other pet is 0%.
local function pityOdds(egg: GameData.Egg): Odds
	local legendaryWeight, mythicWeight = GameData.pityWeights()
	local legendarySum, mythicSum = 0, 0
	for _, row in egg.pets do
		local rarity = rarityOf(row.petId)
		if rarity == "Legendary" then
			legendarySum += row.weight
		elseif rarity == "Mythic" then
			mythicSum += row.weight
		end
	end
	local out: Odds = {}
	for _, row in egg.pets do
		local rarity = rarityOf(row.petId)
		local weight = 0
		if rarity == "Legendary" and legendarySum > 0 then
			weight = legendaryWeight * row.weight / legendarySum
		elseif rarity == "Mythic" and mythicSum > 0 then
			weight = mythicWeight * row.weight / mythicSum
		end
		table.insert(out, { petId = row.petId, weight = weight })
	end
	return out
end

local function oddsText(weight: number): string
	return if weight <= 0 then "0%" else NumberFormat.oddsPercent(weight)
end

local function oddsLine(odds: Odds): string
	local parts = {}
	for _, row in odds do
		local pet = GameData.pet(row.petId)
		table.insert(parts, `{if pet then pet.name else row.petId} {oddsText(row.weight)}`)
	end
	return table.concat(parts, ", ")
end

-- Hatch index (1-based) inside a pack of `count` that is the pity hatch, or nil (counter `c`, pity every `p`).
local function pityHatchIndex(c: number, p: number, count: number): number?
	local index = (p - 1) - c + 1
	if index >= 1 and index <= count then
		return index
	end
	return nil
end

-- Per-hatch odds text for the confirmation step and the 3-pack list.
local function packOddsText(egg: GameData.Egg, count: number): string
	local c, p = pityCount(egg.id), pityAt(egg.id)
	local pityIndex = pityHatchIndex(c, p, count)
	local base = oddsLine(baseOdds(egg))
	if count == 1 then
		return if pityIndex then `Your next hatch (pity): {oddsLine(pityOdds(egg))}` else `Odds: {base}`
	end
	local lines = {}
	for i = 1, count do
		if i == pityIndex then
			local cond = if i > 1
				then ` (pity, if hatches 1-{i - 1} give no Legendary or better; otherwise the base odds)`
				else " (pity)"
			table.insert(lines, `Hatch {i}{cond}: {oddsLine(pityOdds(egg))}`)
		else
			table.insert(lines, `Hatch {i}: {base}`)
		end
	end
	if pityIndex == nil then
		table.insert(lines, PACK_NOTE)
	end
	return table.concat(lines, "\n")
end

-- Panel --------------------------------------------------------------------------------------------------

local function clearRows(list: ScrollingFrame)
	for _, child in list:GetChildren() do
		if child:IsA("Frame") or child:IsA("TextLabel") then
			child:Destroy()
		end
	end
end

local function addNote(list: ScrollingFrame, order: number, text: string, color: Color3?, heightPx: number?)
	local note = Ui.label({
		Name = "Note",
		LayoutOrder = order,
		Text = text,
		TextWrapped = true,
		TextColor3 = color or Theme.textDim,
		Size = UDim2.new(1, -10, 0, heightPx or 44),
		Parent = list,
	})
	Ui.textLimit(18).Parent = note
end

local function addOddsRow(list: ScrollingFrame, order: number, petId: string, weight: number, owned: boolean)
	local pet = GameData.pet(petId)
	local rarity = if pet then pet.rarity else "Common"
	local row = Ui.new("Frame", {
		Name = petId,
		LayoutOrder = order,
		BackgroundColor3 = Theme.panelLight,
		Size = UDim2.new(1, -10, 0, ROW_PX),
		Parent = list,
	}, { Ui.corner(0.2), Ui.new("UIStroke", { Color = Ui.rarityColor(rarity), Thickness = 2 }) })
	local name = Ui.label({
		Text = if pet then pet.name else petId,
		TextXAlignment = Enum.TextXAlignment.Left,
		Position = UDim2.fromScale(0.03, 0.06),
		Size = UDim2.fromScale(0.5, 0.52),
		Parent = row,
	})
	Ui.textLimit(22).Parent = name
	local detail = Ui.label({
		Text = `{rarity}  +{if pet then string.format("%.2f", pet.bonus) else "?"} MP bonus`,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = Ui.rarityColor(rarity),
		Position = UDim2.fromScale(0.03, 0.58),
		Size = UDim2.fromScale(0.5, 0.36),
		Parent = row,
	})
	Ui.textLimit(16).Parent = detail
	local odds = Ui.label({
		Text = oddsText(weight),
		TextColor3 = Theme.accent,
		Position = UDim2.fromScale(0.55, 0.1),
		Size = UDim2.fromScale(0.22, 0.8),
		Parent = row,
	})
	Ui.textLimit(24).Parent = odds
	local tick = Ui.label({
		Text = if owned then "Owned" else "",
		TextColor3 = Theme.good,
		Position = UDim2.fromScale(0.78, 0.1),
		Size = UDim2.fromScale(0.2, 0.8),
		Parent = row,
	})
	Ui.textLimit(18).Parent = tick
end

local function restrictedText(eggId: string): string
	local info = EGG_PRODUCTS[eggId]
	local grant = ProductCatalog.restrictedGrant(info.one)
	local pack = ProductCatalog.restrictedGrant(info.three)
	local pet = GameData.pet(grant.petId)
	local petName = if pet then pet.name else grant.petId
	return `{RESTRICTED_TEXT}. If a purchase still goes through, you get {petName} (no random roll). `
		.. `A 3-pack gives {pack.count} {petName}.`
end

-- Why buying `key` can't start right now (display mirror of the server gate), or nil.
local function buyBlocked(key: Types.ProductKey): string?
	local entry = ProductCatalog.Entries[key]
	if not ProductCatalog.canSell(key) then
		return "Coming soon"
	end
	if not Ui.boolAttr(Attr.FirstWin) then
		return "Win a boss first"
	end
	if GameData.inventoryCap() - Ui.numAttr(Attr.PetCount, 0) < (entry.count or 1) then
		return "Pets full"
	end
	return nil
end

local function setBuyButton(button: TextButton, key: Types.ProductKey, label: string)
	local entry = ProductCatalog.Entries[key]
	local blocked = buyBlocked(key)
	if not entry.onSale then
		button.Visible = false
		return
	end
	button.Visible = true
	if blocked then
		button.Text = `{label}: {blocked}`
		Ui.setEnabled(button, false)
	else
		button.Text = `{label}: {entry.priceLabel}`
		Ui.setEnabled(button, true, Theme.good)
	end
end

local function render()
	local elements = ui
	local eggId = currentEggId
	local egg = if eggId then GameData.egg(eggId) else nil
	local info = if eggId then EGG_PRODUCTS[eggId] else nil
	if elements == nil or egg == nil or info == nil then
		return
	end
	elements.panel.title.Text = egg.name
	clearRows(elements.list)

	if not Ui.boolAttr(Attr.PaidRandomAllowed) then
		elements.pity.Text = ""
		elements.rule.Text = ""
		addNote(elements.list, 1, restrictedText(egg.id), Theme.text, 120)
		elements.list.CanvasPosition = Vector2.zero
		elements.buy1.Visible = false
		elements.buy3.Visible = false
		elements.status.Text = ""
		return
	end

	local c, p = pityCount(egg.id), pityAt(egg.id)
	elements.pity.Text = `Pity: {c}/{p}`
	elements.rule.Text = PITY_RULE
	if not egg.oddsValid then
		addNote(elements.list, 1, "Odds unavailable - try again later")
		elements.buy1.Visible = false
		elements.buy3.Visible = false
		return
	end
	local owned = PetInventory.ownedIds()
	local atPity = c == p - 1
	local odds = if atPity then pityOdds(egg) else baseOdds(egg)
	addNote(
		elements.list,
		0,
		if atPity then "Your next hatch is the pity hatch. Real odds:" else "Odds for every hatch:",
		Theme.accent
	)
	for order, row in odds do
		addOddsRow(elements.list, order, row.petId, row.weight, owned[row.petId] == true)
	end
	addNote(elements.list, #odds + 1, PACK_NOTE)
	if atPity then
		addNote(
			elements.list,
			#odds + 2,
			`After the pity hatch the odds go back to: {oddsLine(baseOdds(egg))}`,
			nil,
			66
		)
	end
	if pityHatchIndex(c, p, 3) ~= nil then
		addNote(elements.list, #odds + 3, `3-pack, odds per hatch:\n{packOddsText(egg, 3)}`, Theme.text, 150)
	end
	setBuyButton(elements.buy1, info.one, "Buy 1")
	setBuyButton(elements.buy3, info.three, "Buy 3")
	elements.status.Text = `Pets: {math.floor(Ui.numAttr(Attr.PetCount, 0))}/{GameData.inventoryCap()}`
end

-- Confirmation step (legal 2.1 a: odds and pity in the confirmation step too) -------------------------------

local function renderConfirm()
	local c = confirmUi
	local key = confirmKey
	local eggId = currentEggId
	local egg = if eggId then GameData.egg(eggId) else nil
	if c == nil or key == nil or egg == nil then
		return
	end
	local entry = ProductCatalog.Entries[key]
	local count = entry.count or 1
	c.title.Text = `{entry.displayName} for {entry.priceLabel}?`
	c.body.Text = `Pity: {pityCount(egg.id)}/{pityAt(egg.id)}. {PITY_RULE}\n{packOddsText(egg, count)}`
	local blocked = buyBlocked(key)
	if not Ui.boolAttr(Attr.PaidRandomAllowed) then
		blocked = "Not available"
	end
	if blocked then
		c.buy.Text = blocked
		Ui.setEnabled(c.buy, false)
	else
		c.buy.Text = `Buy {entry.priceLabel}`
		Ui.setEnabled(c.buy, true, Theme.good)
	end
end

local function openConfirm(key: Types.ProductKey)
	local c = confirmUi
	if c == nil or not Ui.boolAttr(Attr.PaidRandomAllowed) or buyBlocked(key) ~= nil then
		return
	end
	confirmKey = key
	renderConfirm()
	c.root.Visible = true
end

local function closeConfirm()
	local c = confirmUi
	if c then
		c.root.Visible = false
	end
	confirmKey = nil
end

local function onConfirmBuy(remote: RemoteEvent)
	local key = confirmKey
	if key == nil or not Ui.boolAttr(Attr.PaidRandomAllowed) or buyBlocked(key) ~= nil then
		return
	end
	local now = os.clock()
	if now - lastBuyAt < BUY_DEBOUNCE_SEC then
		return
	end
	lastBuyAt = now
	remote:FireServer(key) -- only the key; the server gates it and opens the Roblox prompt
	closeConfirm()
end

local function buildConfirm(remote: RemoteEvent): Confirm
	local screen = Ui.screen("RobuxEggConfirm", 26)
	local root = Ui.new("Frame", {
		Name = "Confirm",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(0.62, 0.62),
		BackgroundColor3 = Theme.panel,
		Visible = false,
		Parent = screen,
	}, { Ui.corner(0.06), Ui.stroke(3), Ui.sizeLimit(310, 280, 600, 460) })
	local title = Ui.label({
		Name = "Title",
		TextColor3 = Theme.accent,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.fromScale(0.5, 0.04),
		Size = UDim2.fromScale(0.9, 0.12),
		Parent = root,
	})
	Ui.textLimit(28).Parent = title
	local body = Ui.label({
		Name = "Odds",
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.fromScale(0.5, 0.18),
		Size = UDim2.fromScale(0.9, 0.58),
		Parent = root,
	})
	Ui.textLimit(17, 9).Parent = body
	local buy = Ui.button({
		Name = "Buy",
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0.05, 0, 1, -10),
		Size = UDim2.fromScale(0.43, 0.16),
		Parent = root,
	})
	Ui.textLimit(24).Parent = buy
	local back = Ui.button({
		Name = "Back",
		Text = "Back",
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(0.95, 0, 1, -10),
		Size = UDim2.fromScale(0.43, 0.16),
		Parent = root,
	})
	Ui.textLimit(24).Parent = back
	buy.Activated:Connect(function()
		onConfirmBuy(remote)
	end)
	back.Activated:Connect(closeConfirm)
	return { screen = screen, root = root, title = title, body = body, buy = buy, back = back }
end

local function build(): Elements
	local panel = Ui.panel(
		"RobuxEggShop",
		"Robux Egg",
		21,
		Vector2.new(0.64, 0.84),
		Vector2.new(310, 360),
		Vector2.new(600, 640)
	)
	local pity = Ui.label({
		Name = "Pity",
		TextColor3 = Theme.accent,
		Size = UDim2.fromScale(1, 0.07),
		Parent = panel.body,
	})
	Ui.textLimit(22).Parent = pity
	local rule = Ui.label({
		Name = "PityRule",
		TextWrapped = true,
		TextColor3 = Theme.text,
		Position = UDim2.fromScale(0, 0.07),
		Size = UDim2.fromScale(1, 0.12),
		Parent = panel.body,
	})
	Ui.textLimit(17, 9).Parent = rule
	local list = Ui.scrollList({
		Name = "Odds",
		Position = UDim2.fromScale(0, 0.2),
		Size = UDim2.fromScale(1, 0.53),
		Parent = panel.body,
	}, 4)
	local status = Ui.label({
		Name = "Status",
		TextColor3 = Theme.textDim,
		Position = UDim2.fromScale(0, 0.74),
		Size = UDim2.fromScale(1, 0.07),
		Parent = panel.body,
	})
	Ui.textLimit(18).Parent = status
	local function buyButton(name: string, x: number, pack: "one" | "three"): TextButton
		local button = Ui.button({
			Name = name,
			AnchorPoint = Vector2.new(x, 1),
			Position = UDim2.fromScale(x, 1),
			Size = UDim2.fromScale(0.48, 0.16),
			Parent = panel.body,
		})
		Ui.textLimit(22).Parent = button
		button.Activated:Connect(function()
			local info = if currentEggId then EGG_PRODUCTS[currentEggId] else nil
			if info then
				openConfirm(if pack == "one" then info.one else info.three)
			end
		end)
		return button
	end
	local buy1 = buyButton("Buy1", 0, "one")
	local buy3 = buyButton("Buy3", 1, "three")
	return { panel = panel, pity = pity, rule = rule, list = list, status = status, buy1 = buy1, buy3 = buy3 }
end

local function close()
	local elements = ui
	if elements then
		elements.panel.root.Visible = false
	end
	closeConfirm()
	currentEggId = nil
end

local function open(eggId: string)
	local elements = ui
	if elements == nil or EGG_PRODUCTS[eggId] == nil or not Ui.boolAttr(Attr.DataLoaded) then
		return
	end
	UiEvents.fireOpenPanel(PANEL_NAME) -- closes every other panel
	currentEggId = eggId
	elements.panel.root.Visible = true
	render()
end

-- True for the egg ids this panel handles (Robux eggs).
function RobuxEggPanel.handles(eggId: string): boolean
	return EGG_PRODUCTS[eggId] ~= nil
end

-- Lifecycle (called by EggController:Start) ---------------------------------------------------------------

function RobuxEggPanel.start()
	local player = Players.LocalPlayer
	local remote = Remotes.getEvent("RequestPurchase")
	local elements = build()
	ui = elements
	confirmUi = buildConfirm(remote)
	elements.panel.close.Activated:Connect(close)

	UiEvents.OpenRobuxEgg:Connect(open)
	UiEvents.OpenPanel:Connect(function(name: string)
		if name ~= PANEL_NAME then
			close()
		end
	end)
	local function onChange()
		if elements.panel.root.Visible then
			render()
		end
		if confirmKey then
			renderConfirm()
		end
	end
	for _, name in
		{
			Attr.PaidRandomAllowed,
			Attr.PityStarEgg,
			Attr.PityGalaxyEgg,
			Attr.PetCount,
			Attr.FirstWin,
		}
	do
		player:GetAttributeChangedSignal(name):Connect(onChange)
	end
	PetInventory.onChanged(onChange)
end

return RobuxEggPanel
