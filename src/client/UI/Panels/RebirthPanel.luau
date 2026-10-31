--!strict
-- RebirthPanel: the rebirth confirm screen (helper, not a controller: HudController starts it). Owned by
-- systems-programmer. Contract: architecture 2 #5 (RequestRebirth, no arguments), 1e (RebirthCost, Rebirths,
-- InDuel), GDD 4.5 (rev 1: no paid skip), D-034 (World 2 is "coming Saturday", never unlocked in v1).
--
-- * Opens from the HUD rebirth button (UiEvents "Rebirth"). Shows the cost (server `RebirthCost` attribute;
--   EconomyConfig.rebirthCost only as a display fallback), what resets (MP, coins, tools), what stays (pods,
--   pets, rank and look, paid items, codes), the bonus (MP and coin multipliers before -> after) and what the
--   next rebirth unlocks (Auto-Mog, Hatch x3, a pet slot).
-- * Shows "World 2 coming Saturday!" instead of a World 2 unlock (D-034).
-- * The REBIRTH button fires `RequestRebirth()` once (debounced) and closes the panel. RebirthService recomputes
--   the cost, checks coins and duels, and resets atomically; nothing is predicted on the client.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Contracts = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Contracts")
local NumberFormat = require(Contracts:WaitForChild("NumberFormat"))
local Remotes = require(Contracts:WaitForChild("Remotes"))
local Types = require(Contracts:WaitForChild("Types"))

local GameData = require(script.Parent.Parent.Util.GameData)
local Ui = require(script.Parent.Parent.Util.Ui)
local UiEvents = require(script.Parent.Parent.Util.UiEvents)

local Attr = Types.PlayerAttr
local Theme = Ui.Theme

local REBIRTH_DEBOUNCE_SEC = 2 -- RequestRebirth allows 0.5/s
local WORLD2_NOTICE = "World 2 coming Saturday!"

local RebirthPanel = {}

type Elements = {
	panel: Ui.Panel,
	cost: TextLabel,
	bonus: TextLabel,
	unlock: TextLabel,
	confirm: TextButton,
}

local ui: Elements? = nil
local lastRequestAt = 0

-- Coins needed for the next rebirth: the server's attribute, else the shared formula (display only).
function RebirthPanel.cost(): number?
	local attr = Ui.numAttr(Attr.RebirthCost, 0)
	if attr > 0 then
		return attr
	end
	return GameData.rebirthCost(math.floor(Ui.numAttr(Attr.Rebirths, 0)) + 1)
end

-- True when the player has the coins for the next rebirth (drives the HUD "REBIRTH READY" pulse).
function RebirthPanel.isReady(): boolean
	local cost = RebirthPanel.cost()
	return cost ~= nil and Ui.boolAttr(Attr.DataLoaded) and Ui.numAttr(Attr.Coins, 0) >= cost
end

local function unlockText(nextRebirth: number): string
	local parts = {}
	if nextRebirth == GameData.autoMogRebirths() then
		table.insert(parts, "Auto-Mog")
	end
	if nextRebirth == GameData.hatchThreeRebirths() then
		table.insert(parts, "Hatch x3")
	end
	if table.find(GameData.petSlotRebirths(), nextRebirth) then
		table.insert(parts, "+1 pet slot")
	end
	if #parts == 0 then
		return ""
	end
	return "Unlocks: " .. table.concat(parts, ", ") .. "!"
end

local function refresh()
	local elements = ui
	if elements == nil or not elements.panel.root.Visible then
		return
	end
	local rebirths = math.floor(Ui.numAttr(Attr.Rebirths, 0))
	local nextRebirth = rebirths + 1
	local cost = RebirthPanel.cost()
	local coins = Ui.numAttr(Attr.Coins, 0)

	elements.panel.title.Text = `Rebirth {nextRebirth}`
	elements.cost.Text = if cost
		then `Cost: {NumberFormat.abbreviate(cost)} Coins (you: {NumberFormat.abbreviate(coins)})`
		else "Cost: -"
	local mpBefore, mpAfter = GameData.rebirthMult(rebirths), GameData.rebirthMult(nextRebirth)
	local coinBefore, coinAfter = GameData.coinRebirthMult(rebirths), GameData.coinRebirthMult(nextRebirth)
	elements.bonus.Text = `MP {NumberFormat.multiplier(mpBefore)} -> {NumberFormat.multiplier(mpAfter)}, `
		.. `coins {NumberFormat.multiplier(coinBefore)} -> {NumberFormat.multiplier(coinAfter)}`
	elements.unlock.Text = unlockText(nextRebirth)

	local confirm = elements.confirm
	if Ui.boolAttr(Attr.InDuel) then
		confirm.Text = "Finish your duel first"
		Ui.setEnabled(confirm, false)
	elseif cost == nil or coins < cost then
		confirm.Text = if cost then `Need {NumberFormat.abbreviate(cost)} Coins` else "Not ready"
		Ui.setEnabled(confirm, false)
	else
		confirm.Text = "REBIRTH!"
		Ui.setEnabled(confirm, true, Theme.accent)
	end
end

local function line(
	parent: Instance,
	name: string,
	order: number,
	heightScale: number,
	color: Color3?
): TextLabel
	local label = Ui.label({
		Name = name,
		LayoutOrder = order,
		Size = UDim2.fromScale(1, heightScale),
		TextColor3 = color or Theme.text,
		Parent = parent,
	})
	Ui.textLimit(22).Parent = label
	return label
end

local function build(requestRebirth: RemoteEvent): Elements
	local panel = Ui.panel(
		"Rebirth",
		"Rebirth",
		22,
		Vector2.new(0.55, 0.72),
		Vector2.new(300, 300),
		Vector2.new(520, 520)
	)
	local column = Ui.new("Frame", {
		Name = "Column",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 0.78),
		Parent = panel.body,
	}, {
		Ui.new("UIListLayout", {
			FillDirection = Enum.FillDirection.Vertical,
			HorizontalAlignment = Enum.HorizontalAlignment.Center,
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0.015, 0),
		}),
	})
	local cost = line(column, "Cost", 1, 0.13, Theme.coins)
	line(column, "Resets", 2, 0.12, Theme.bad).Text = "Resets: MP, coins and tools"
	line(column, "Keeps", 3, 0.17, Theme.good).Text = "Keeps: pods, pets, rank and look, paid items, codes"
	local bonus = line(column, "Bonus", 4, 0.13, Theme.accent)
	local unlock = line(column, "Unlock", 5, 0.12)
	line(column, "World2", 6, 0.12, Theme.textDim).Text = WORLD2_NOTICE

	local confirm = Ui.button({
		Name = "Confirm",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.fromScale(0.5, 1),
		Size = UDim2.fromScale(0.7, 0.18),
		Parent = panel.body,
	})
	Ui.textLimit(30).Parent = confirm
	confirm.Activated:Connect(function()
		local now = os.clock()
		if
			not RebirthPanel.isReady()
			or Ui.boolAttr(Attr.InDuel)
			or now - lastRequestAt < REBIRTH_DEBOUNCE_SEC
		then
			return
		end
		lastRequestAt = now
		requestRebirth:FireServer()
		panel.root.Visible = false
	end)

	return { panel = panel, cost = cost, bonus = bonus, unlock = unlock, confirm = confirm }
end

-- Builds the panel and wires it. Called once from HudController:Start (may yield on Remotes).
function RebirthPanel.start()
	local player = Players.LocalPlayer
	local elements = build(Remotes.getEvent("RequestRebirth"))
	ui = elements

	UiEvents.OpenPanel:Connect(function(name: string)
		if name == "Rebirth" then
			if Ui.boolAttr(Attr.DataLoaded) then
				elements.panel.root.Visible = true
				refresh()
			end
		else
			elements.panel.root.Visible = false
		end
	end)
	for _, name in { Attr.Coins, Attr.Rebirths, Attr.RebirthCost, Attr.InDuel } do
		player:GetAttributeChangedSignal(name):Connect(refresh)
	end
end

return RebirthPanel
