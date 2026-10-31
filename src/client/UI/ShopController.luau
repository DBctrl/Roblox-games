--!strict
-- ShopController: the Tool Stand panel (coins only). Owned by systems-programmer.
-- Contract: architecture 1d #27, section 2 #3 (BuyTool), GDD 4.2 and 8b.
--
-- * Opens from the Tool Stand's ProximityPrompt (MapLayout tells which prompts belong to a "Tools" ShopStand) or
--   the HUD "Tools" button (shown after FirstWin). A prompt only opens UI: never a purchase prompt (GDD 8b).
-- * Shows the current tool and only the NEXT tool (ToolIndex + 1) with its cost and MP per tap. Buy fires
--   `BuyTool(ToolIndex + 1)`; ShopService re-checks index, world unlock and coins on the server.
-- * Coins only. The Robux shop (ladder, boosts, RequestPurchase) is T-057 and is not in this file.

local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Contracts = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Contracts")
local NumberFormat = require(Contracts:WaitForChild("NumberFormat"))
local Remotes = require(Contracts:WaitForChild("Remotes"))
local Types = require(Contracts:WaitForChild("Types"))

local GameData = require(script.Parent.Util.GameData)
local Ui = require(script.Parent.Util.Ui)
local UiEvents = require(script.Parent.Util.UiEvents)

local Attr = Types.PlayerAttr
local Theme = Ui.Theme

local BUY_DEBOUNCE_SEC = 0.5

local ShopController = {}

type Panel = {
	root: Frame,
	current: TextLabel,
	nextName: TextLabel,
	nextInfo: TextLabel,
	buy: TextButton,
}

local panel: Panel? = nil
local lastBuyAt = 0

local function build(): Panel
	local screen = Ui.screen("ToolShop", 20)
	local root = Ui.new("Frame", {
		Name = "ToolShop",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(0.5, 0.55),
		BackgroundColor3 = Theme.panel,
		Visible = false,
		Parent = screen,
	}, {
		Ui.corner(0.08),
		Ui.stroke(3),
		Ui.sizeLimit(290, 230, 520, 380),
	})

	local title = Ui.label({
		Name = "Title",
		Text = "Tool Stand",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.fromScale(0.5, 0.04),
		Size = UDim2.fromScale(0.7, 0.14),
		Parent = root,
	})
	Ui.textLimit(34).Parent = title

	local close = Ui.button({
		Name = "Close",
		Text = "X",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -6, 0, 6),
		Size = UDim2.fromScale(0.12, 0.15),
		BackgroundColor3 = Theme.bad,
		Parent = root,
	})
	Ui.textLimit(26).Parent = close
	close.Activated:Connect(function()
		root.Visible = false
	end)

	local current = Ui.label({
		Name = "Current",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.fromScale(0.5, 0.22),
		Size = UDim2.fromScale(0.9, 0.12),
		TextColor3 = Theme.textDim,
		Parent = root,
	})
	Ui.textLimit(22).Parent = current

	local nextName = Ui.label({
		Name = "NextName",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.fromScale(0.5, 0.38),
		Size = UDim2.fromScale(0.9, 0.16),
		TextColor3 = Theme.accent,
		Parent = root,
	})
	Ui.textLimit(32).Parent = nextName

	local nextInfo = Ui.label({
		Name = "NextInfo",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.fromScale(0.5, 0.55),
		Size = UDim2.fromScale(0.9, 0.12),
		Parent = root,
	})
	Ui.textLimit(24).Parent = nextInfo

	local buy = Ui.button({
		Name = "Buy",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -10),
		Size = UDim2.fromScale(0.6, 0.18),
		Parent = root,
	})
	Ui.textLimit(28).Parent = buy

	return { root = root, current = current, nextName = nextName, nextInfo = nextInfo, buy = buy }
end

-- What the Buy button can do right now: nil index = nothing to buy.
local function nextTool(): (GameData.Tool?, GameData.Tool?, string?)
	local tools = GameData.tools()
	local index = math.floor(Ui.numAttr(Attr.ToolIndex, 1))
	local current = tools[index]
	local candidate = tools[index + 1]
	if candidate == nil then
		return current, nil, "You have the best tool!"
	end
	if candidate.worldId == 2 and not Ui.boolAttr(Attr.World2Unlocked) then
		return current, candidate, "Unlocks in World 2"
	end
	return current, candidate, nil
end

local function refresh()
	local p = panel
	if p == nil or not p.root.Visible then
		return
	end
	local current, candidate, blocked = nextTool()
	p.current.Text = if current
		then `Now: {current.name} (+{NumberFormat.abbreviate(current.power)} MP per tap)`
		else "Now: -"
	if candidate then
		p.nextName.Text = `Next: {candidate.name}`
		p.nextInfo.Text = `+{NumberFormat.abbreviate(candidate.power)} MP per tap`
	else
		p.nextName.Text = blocked or ""
		p.nextInfo.Text = ""
	end

	local coins = Ui.numAttr(Attr.Coins, 0)
	if candidate == nil or blocked then
		p.buy.Text = blocked or "Maxed"
		p.buy.BackgroundColor3 = Theme.grey
		p.buy.AutoButtonColor = false
	elseif coins >= candidate.cost then
		p.buy.Text = `Buy for {NumberFormat.abbreviate(candidate.cost)} Coins`
		p.buy.BackgroundColor3 = Theme.good
		p.buy.AutoButtonColor = true
	else
		p.buy.Text = `Need {NumberFormat.abbreviate(candidate.cost)} Coins`
		p.buy.BackgroundColor3 = Theme.grey
		p.buy.AutoButtonColor = false
	end
end

local function open()
	local p = panel
	if p == nil or not Ui.boolAttr(Attr.DataLoaded) then
		return
	end
	p.root.Visible = true
	refresh()
end

local function onBuy(buyTool: RemoteEvent)
	local _, candidate, blocked = nextTool()
	if candidate == nil or blocked or Ui.numAttr(Attr.Coins, 0) < candidate.cost then
		return
	end
	local now = os.clock()
	if now - lastBuyAt < BUY_DEBOUNCE_SEC then
		return
	end
	lastBuyAt = now
	buyTool:FireServer(candidate.index)
end

function ShopController:Init() end

function ShopController:Start()
	local player = Players.LocalPlayer
	local p = build()
	panel = p

	local buyTool = Remotes.getEvent("BuyTool")
	p.buy.Activated:Connect(function()
		onBuy(buyTool)
	end)

	UiEvents.OpenPanel:Connect(function(name: string)
		if name == "Tools" then
			open()
		end
	end)
	ProximityPromptService.PromptTriggered:Connect(function(prompt: ProximityPrompt, who: Player)
		if who == player and GameData.isShopPrompt(prompt, "Tools") then
			open()
		end
	end)

	for _, name in { Attr.ToolIndex, Attr.Coins, Attr.World2Unlocked } do
		player:GetAttributeChangedSignal(name):Connect(refresh)
	end
end

return ShopController
