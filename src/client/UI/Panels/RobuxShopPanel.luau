--!strict
-- RobuxShopPanel: the Robux shop and the one-time Starter Pack pop-up (helper, not a controller: ShopController
-- starts it). Owned by systems-programmer (T-057). Contract: architecture 1d #27, 2 #13, 4e, 4f; GDD 8 a-i;
-- legal 2.12, 2.14, 2.16, RC-11.
--
-- * Opens from the HUD "Shop" button (shown only after FirstWin, GDD 8a) or a Robux ShopStand prompt. A prompt only
--   opens this UI; it never starts a purchase (GDD 8b, no purchase pads).
-- * Three tabs, so there is never a wall of buy buttons: Boosts (ladder, Hype Snack, Auto Clicker, VIP, Starter
--   Pack), Pets (Ring Light Retriever, and the Robux eggs, which open the egg screen with odds, T-058) and Style
--   (Golden Glow Fit, "Exclusive").
-- * Ladder (GDD 8e, D-016 #8): only tier PaidTier + 1 is listed, named "x2 Mog Points" etc. from the catalog,
--   with the catalog description, which carries the lawyer's exact `ProductCatalog.LADDER_NOTE` (T-071, D-056).
--   Owned and lower tiers are never shown.
-- * Names, prices and descriptions come only from Contracts/ProductCatalog. A Buy press sends only the key with
--   `RequestPurchase`; the server re-runs every gate and opens the prompt itself.
-- * Placeholder ids: `ProductCatalog.canSell` is false ("NoProductId") until the owner creates the products, so
--   every item is still shown, with a grey "Coming soon" button that sends nothing.
-- * Copy never says "money can't affect PvP" (legal RC-11) and never "Limited".

local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Contracts = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Contracts")
local NumberFormat = require(Contracts:WaitForChild("NumberFormat"))
local ProductCatalog = require(Contracts:WaitForChild("ProductCatalog"))
local Remotes = require(Contracts:WaitForChild("Remotes"))
local Types = require(Contracts:WaitForChild("Types"))

local GameData = require(script.Parent.Parent.Util.GameData)
local Ui = require(script.Parent.Parent.Util.Ui)
local UiEvents = require(script.Parent.Parent.Util.UiEvents)

local Attr = Types.PlayerAttr
local Theme = Ui.Theme

local PANEL_NAME = "RobuxShop"
local ROW_PX = 128 -- tall enough for the longest catalog description at the 9 px text floor on a phone
local BUY_DEBOUNCE_SEC = 2.5 -- RequestPurchase allows 0.5/s, burst 2
local BOOST_CAP_SEC = 2 * 60 * 60 -- display fallback; EconomyConfig.BOOST_CAP_SEC is the rule (server)
local LADDER_NOTE = ProductCatalog.LADDER_NOTE -- lawyer's exact wording (T-071); never a local copy
local DUEL_NOTE = "Pets, multipliers, VIP and boosts don't count in duels."

type TabName = "Boosts" | "Pets" | "Style"
type RowKind = "Ladder" | "Product" | "Egg"

type Row = {
	kind: RowKind,
	key: Types.ProductKey?, -- Product rows
	eggId: string?, -- Egg rows
	frame: Frame,
	name: TextLabel,
	info: TextLabel,
	button: TextButton,
}

type Elements = {
	panel: Ui.Panel,
	tabs: { [TabName]: TextButton },
	lists: { [TabName]: ScrollingFrame },
	rows: { Row },
	note: TextLabel,
}

type Popup = {
	screen: ScreenGui,
	root: Frame,
	buy: TextButton,
}

local RobuxShopPanel = {}

local ui: Elements? = nil
local popup: Popup? = nil
local activeTab: TabName = "Boosts"
local lastBuyAt = 0
local popupShown = false

local function serverNow(): number
	return workspace:GetServerTimeNow()
end

local function hypeLeftSec(): number
	return math.max(0, Ui.numAttr(Attr.HypeEndsAt, 0) - serverNow())
end

local function freeSlots(): number
	return GameData.inventoryCap() - math.floor(Ui.numAttr(Attr.PetCount, 0))
end

-- Mirrors the server gate for display only (MonetizationService re-checks everything). nil = can press Buy.
local function blockedText(key: Types.ProductKey): string?
	local entry = ProductCatalog.Entries[key]
	local sellable = ProductCatalog.canSell(key)
	if key == "AutoClicker" and Ui.boolAttr(Attr.AutoClickerOwned) then
		return "Owned"
	elseif key == "Vip" and Ui.boolAttr(Attr.Vip) then
		return "Owned"
	elseif key == "StarterPack" and Ui.boolAttr(Attr.StarterPackOwned) then
		return "Owned"
	end
	if not sellable then
		return "Coming soon"
	end
	if not Ui.boolAttr(Attr.FirstWin) then
		return "Win a boss first"
	end
	if entry.grantKind == "Boost" and entry.hypeSec and hypeLeftSec() + entry.hypeSec > BOOST_CAP_SEC then
		return "At 2 h limit"
	end
	if (entry.grantKind == "FixedPet" or entry.grantKind == "StarterPack") and freeSlots() < 1 then
		return "Pets full"
	end
	return nil
end

local function ladderEntry(): ProductCatalog.Entry?
	local tier = math.floor(Ui.numAttr(Attr.PaidTier, 0))
	local key = ProductCatalog.ladderKey(tier + 1)
	return if key then ProductCatalog.Entries[key] else nil
end

local function setBuy(button: TextButton, priceLabel: string, blocked: string?)
	if blocked then
		button.Text = blocked
		Ui.setEnabled(button, false)
	else
		button.Text = priceLabel
		Ui.setEnabled(button, true, Theme.good)
	end
end

local function refresh()
	local elements = ui
	if elements == nil or not elements.panel.root.Visible then
		return
	end
	for name, list in elements.lists do
		list.Visible = name == activeTab
	end
	for name, tab in elements.tabs do
		tab.BackgroundColor3 = if name == activeTab then Theme.accent else Theme.panelLight
	end
	for _, row in elements.rows do
		if row.kind == "Ladder" then
			local entry = ladderEntry()
			local owned = math.floor(Ui.numAttr(Attr.PaidTier, 0))
			if entry == nil then
				row.name.Text = "x32 Mog Points"
				row.info.Text = `You own the top tier. {LADDER_NOTE}`
				setBuy(row.button, "", "Owned")
			else
				row.name.Text = entry.displayName
				local ownedText = if owned > 0 then ` You own x{2 ^ owned}.` else ""
				row.info.Text = `{entry.description}{ownedText}`
				setBuy(row.button, entry.priceLabel, blockedText(entry.key))
			end
		elseif row.kind == "Product" and row.key then
			local entry = ProductCatalog.Entries[row.key]
			local info = entry.description
			if row.key == "HypeSnack" then
				local left = hypeLeftSec()
				if left > 0 then
					info ..= ` Now: {NumberFormat.duration(left)} of 2:00:00.`
				end
			end
			row.info.Text = info
			setBuy(row.button, entry.priceLabel, blockedText(row.key))
		elseif row.kind == "Egg" then
			row.button.Text = "Odds Info"
			Ui.setEnabled(row.button, true, Theme.accent)
		end
	end
end

local function requestPurchase(remote: RemoteEvent, key: Types.ProductKey)
	if blockedText(key) ~= nil then
		return
	end
	local now = os.clock()
	if now - lastBuyAt < BUY_DEBOUNCE_SEC then
		return
	end
	lastBuyAt = now
	remote:FireServer(key) -- only the key; the server checks the gates and opens the prompt
end

local function addRow(
	list: ScrollingFrame,
	order: number,
	title: string,
	badge: string?
): (Frame, TextLabel, TextLabel, TextButton)
	local frame = Ui.new("Frame", {
		Name = `Row{order}`,
		LayoutOrder = order,
		BackgroundColor3 = Theme.panelLight,
		Size = UDim2.new(1, -10, 0, ROW_PX),
		Parent = list,
	}, { Ui.corner(0.15) })
	local name = Ui.label({
		Name = "Name",
		Text = title,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = Theme.accent,
		Position = UDim2.fromScale(0.03, 0.05),
		Size = UDim2.fromScale(if badge then 0.42 else 0.64, 0.34),
		Parent = frame,
	})
	Ui.textLimit(24).Parent = name
	if badge then
		local tag = Ui.label({
			Name = "Badge",
			Text = badge,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextColor3 = Theme.good,
			Position = UDim2.fromScale(0.46, 0.08),
			Size = UDim2.fromScale(0.21, 0.28),
			Parent = frame,
		})
		Ui.textLimit(16).Parent = tag
	end
	local info = Ui.label({
		Name = "Info",
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		TextWrapped = true,
		TextColor3 = Theme.textDim,
		Position = UDim2.fromScale(0.03, 0.42),
		Size = UDim2.fromScale(0.66, 0.54),
		Parent = frame,
	})
	Ui.textLimit(14, 9).Parent = info
	local button = Ui.button({
		Name = "Buy",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -8, 0.5, 0),
		Size = UDim2.new(0.28, 0, 0, 56),
		Parent = frame,
	})
	Ui.textLimit(22).Parent = button
	return frame, name, info, button
end

local function build(requestRemote: RemoteEvent): Elements
	local panel = Ui.panel(
		PANEL_NAME,
		"Shop",
		22,
		Vector2.new(0.66, 0.84),
		Vector2.new(320, 340),
		Vector2.new(640, 620)
	)
	local tabBar = Ui.new("Frame", {
		Name = "Tabs",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 48),
		Parent = panel.body,
	}, {
		Ui.new("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal,
			HorizontalAlignment = Enum.HorizontalAlignment.Center,
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0.02, 0),
		}),
	})
	local tabs: { [TabName]: TextButton } = {}
	local lists: { [TabName]: ScrollingFrame } = {}
	local rows: { Row } = {}
	local tabNames: { TabName } = { "Boosts", "Pets", "Style" }
	for order, name in tabNames do
		local tab = Ui.button({
			Name = name,
			Text = name,
			LayoutOrder = order,
			Size = UDim2.new(0.31, 0, 1, 0),
			Parent = tabBar,
		})
		Ui.textLimit(22).Parent = tab
		tab.Activated:Connect(function()
			activeTab = name
			refresh()
		end)
		tabs[name] = tab
		lists[name] = Ui.scrollList({
			Name = `{name}List`,
			Position = UDim2.new(0, 0, 0, 54),
			Size = UDim2.new(1, 0, 0.9, -54),
			Visible = false,
			Parent = panel.body,
		}, 6)
	end

	-- Boosts tab: the next ladder tier only, then the other power and convenience items.
	do
		local frame, name, info, button = addRow(lists.Boosts, 1, "", "Permanent")
		table.insert(rows, { kind = "Ladder", frame = frame, name = name, info = info, button = button })
		button.Activated:Connect(function()
			local entry = ladderEntry()
			if entry then
				requestPurchase(requestRemote, entry.key)
			end
		end)
	end
	local function productRow(tab: TabName, order: number, key: Types.ProductKey, badge: string?)
		local entry = ProductCatalog.Entries[key]
		if not entry.onSale then
			return -- outside today's scope (D-038): never listed
		end
		local frame, name, info, button = addRow(lists[tab], order, entry.displayName, badge)
		table.insert(
			rows,
			{ kind = "Product", key = key, frame = frame, name = name, info = info, button = button }
		)
		button.Activated:Connect(function()
			requestPurchase(requestRemote, key)
		end)
	end
	productRow("Boosts", 2, "HypeSnack", nil)
	productRow("Boosts", 3, "AutoClicker", "Permanent")
	productRow("Boosts", 4, "Vip", "Permanent")
	productRow("Boosts", 5, "StarterPack", "One time")

	-- Pets tab: the fixed pet, then the Robux eggs (their buy step lives on the egg screen with the odds).
	productRow("Pets", 1, "RingLightRetriever", "Not random")
	for order, eggId in { "StarEgg", "GalaxyEgg" } do
		local egg = GameData.egg(eggId)
		local frame, name, info, button =
			addRow(lists.Pets, order + 1, if egg then egg.name else eggId, "Random")
		info.Text = "Random pet. Tap Odds Info to see the exact odds and the pity rule before you buy."
		table.insert(
			rows,
			{ kind = "Egg", eggId = eggId, frame = frame, name = name, info = info, button = button }
		)
		button.Activated:Connect(function()
			UiEvents.fireOpenRobuxEgg(eggId)
		end)
	end

	-- Style tab: exclusive cosmetics (never "Limited", legal 2.16).
	productRow("Style", 1, "GoldenGlowFit", "Exclusive")
	productRow("Style", 2, "NeonIconFit", "Exclusive") -- not on sale in v1: skipped by productRow

	local note = Ui.label({
		Name = "Note",
		Text = DUEL_NOTE,
		TextColor3 = Theme.textDim,
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.fromScale(0.5, 1),
		Size = UDim2.fromScale(1, 0.08),
		Parent = panel.body,
	})
	Ui.textLimit(16).Parent = note
	return { panel = panel, tabs = tabs, lists = lists, rows = rows, note = note }
end

local function open()
	local elements = ui
	if elements == nil or not Ui.boolAttr(Attr.DataLoaded) or not Ui.boolAttr(Attr.FirstWin) then
		return -- GDD 8a: no shop before the first boss win
	end
	elements.panel.root.Visible = true
	refresh()
end

-- Starter Pack pop-up (GDD 8c): once, after the first rank-up, closable, never before FirstWin. ---------------

local function buildPopup(requestRemote: RemoteEvent): Popup
	local entry = ProductCatalog.Entries.StarterPack
	local screen = Ui.screen("StarterPackPopup", 24)
	local root = Ui.new("Frame", {
		Name = "StarterPack",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(0.5, 0.45),
		BackgroundColor3 = Theme.panel,
		Visible = false,
		Parent = screen,
	}, { Ui.corner(0.08), Ui.stroke(3), Ui.sizeLimit(290, 220, 480, 340) })
	local title = Ui.label({
		Name = "Title",
		Text = "Starter Pack",
		TextColor3 = Theme.accent,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.fromScale(0.5, 0.05),
		Size = UDim2.fromScale(0.8, 0.16),
		Parent = root,
	})
	Ui.textLimit(32).Parent = title
	local info = Ui.label({
		Name = "Info",
		Text = entry.description,
		TextWrapped = true,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.fromScale(0.5, 0.25),
		Size = UDim2.fromScale(0.9, 0.38),
		Parent = root,
	})
	Ui.textLimit(20).Parent = info
	local buy = Ui.button({
		Name = "Buy",
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0.05, 0, 1, -10),
		Size = UDim2.fromScale(0.43, 0.2),
		Parent = root,
	})
	Ui.textLimit(24).Parent = buy
	local later = Ui.button({
		Name = "Close",
		Text = "No thanks",
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(0.95, 0, 1, -10),
		Size = UDim2.fromScale(0.43, 0.2),
		Parent = root,
	})
	Ui.textLimit(24).Parent = later
	later.Activated:Connect(function()
		root.Visible = false
	end)
	buy.Activated:Connect(function()
		requestPurchase(requestRemote, "StarterPack")
		root.Visible = false
	end)
	return { screen = screen, root = root, buy = buy }
end

local function maybeShowPopup(oldRank: number, newRank: number)
	local p = popup
	if p == nil or popupShown or oldRank ~= 1 or newRank < 2 then
		return -- the first rank-up (1 -> 2) happens once per profile, so this shows once
	end
	if Ui.boolAttr(Attr.StarterPackOwned) or not Ui.boolAttr(Attr.FirstWin) then
		return
	end
	if not ProductCatalog.Entries.StarterPack.onSale then
		return
	end
	popupShown = true
	setBuy(p.buy, ProductCatalog.Entries.StarterPack.priceLabel, blockedText("StarterPack"))
	task.delay(4, function() -- let the rank-up moment (CinematicController) play first
		if not Ui.boolAttr(Attr.StarterPackOwned) then
			p.root.Visible = true
		end
	end)
end

-- Lifecycle (called by ShopController:Start) -------------------------------------------------------------

function RobuxShopPanel.start()
	local player = Players.LocalPlayer
	local requestRemote = Remotes.getEvent("RequestPurchase")
	local elements = build(requestRemote)
	ui = elements
	popup = buildPopup(requestRemote)

	UiEvents.OpenPanel:Connect(function(name: string)
		if name == PANEL_NAME then
			open()
		else
			elements.panel.root.Visible = false
		end
	end)
	ProximityPromptService.PromptTriggered:Connect(function(prompt: ProximityPrompt, who: Player)
		if who == player and GameData.isShopPrompt(prompt, "Robux") then
			UiEvents.fireOpenPanel(PANEL_NAME)
		end
	end)
	for _, name in
		{
			Attr.PaidTier,
			Attr.Vip,
			Attr.AutoClickerOwned,
			Attr.StarterPackOwned,
			Attr.HypeEndsAt,
			Attr.PetCount,
			Attr.FirstWin,
		}
	do
		player:GetAttributeChangedSignal(name):Connect(refresh)
	end
	-- The first Rank value seen is the saved rank (a baseline, not a rank-up); only a later 1 -> 2 change counts.
	local rawRank = player:GetAttribute(Attr.Rank)
	local lastRank: number? = if type(rawRank) == "number" then math.floor(rawRank) else nil
	player:GetAttributeChangedSignal(Attr.Rank):Connect(function()
		local rank = math.floor(Ui.numAttr(Attr.Rank, 1))
		if lastRank ~= nil then
			maybeShowPopup(lastRank, rank)
		end
		lastRank = rank
	end)
	-- Hype Snack time left ticks down: refresh the open panel once per second.
	task.spawn(function()
		while player.Parent do
			task.wait(1)
			if elements.panel.root.Visible and activeTab == "Boosts" then
				refresh()
			end
		end
	end)
end

return RobuxShopPanel
