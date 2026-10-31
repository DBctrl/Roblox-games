--!strict
-- ShopController: the Tool Stand panel (coins only). Owned by systems-programmer.
-- Contract: architecture 1d #27, section 2 #3 (BuyTool), GDD 4.2 and 8b.
--
-- * Opens from the Tool Stand's ProximityPrompt (MapLayout tells which prompts belong to a "Tools" ShopStand) or
--   the HUD "Tools" button (shown after FirstWin). A prompt only opens UI: never a purchase prompt (GDD 8b).
-- * Shows the current tool and only the NEXT tool (ToolIndex + 1) with its cost and MP per tap. Buy fires
--   `BuyTool(ToolIndex + 1)`; ShopService re-checks index, world unlock and coins on the server.
-- * Coins only. The Robux shop (ladder, boosts, RequestPurchase) is T-057 and is not in this file.
-- * Pod shop (T-034, GDD 4.3): opened from the HUD "Pods" button. Lists the World 1 Glow Pods with base MP/s and
--   coin cost; owned pods (PodsMask bit i, architecture 1e) say "Owned" or "You're here" (CurrentPod). Buy fires
--   `BuyPod(index)`; ShopService re-checks ownership, world unlock and coins. World 2 pods arrive with Update 1,
--   so the list ends with "More pods in World 2 - coming Saturday!" (D-034).

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

-- Pod shop (T-034) -------------------------------------------------------------------------------------

local POD_ROW_PX = 64
local WORLD2_NOTICE = "More pods in World 2 - coming Saturday!"

type PodRow = { pod: GameData.Pod, buy: TextButton }

local podPanel: Ui.Panel? = nil
local podRows: { PodRow } = {}
local lastPodBuyAt = 0

local function podOwned(index: number): boolean
	local mask = math.floor(Ui.numAttr(Attr.PodsMask, 0))
	return bit32.btest(mask, bit32.lshift(1, index)) -- bit i = pod i (architecture 1e)
end

local function refreshPods()
	local p = podPanel
	if p == nil or not p.root.Visible then
		return
	end
	local coins = Ui.numAttr(Attr.Coins, 0)
	local here = math.floor(Ui.numAttr(Attr.CurrentPod, 0))
	for _, row in podRows do
		local pod = row.pod
		if podOwned(pod.index) then
			row.buy.Text = if here == pod.index then "You're here" else "Owned"
			Ui.setEnabled(row.buy, false)
		elseif coins >= pod.cost then
			row.buy.Text = `Buy {NumberFormat.abbreviate(pod.cost)}`
			Ui.setEnabled(row.buy, true)
		else
			row.buy.Text = `Need {NumberFormat.abbreviate(pod.cost)}`
			Ui.setEnabled(row.buy, false)
		end
	end
end

local function onBuyPod(buyPod: RemoteEvent, pod: GameData.Pod)
	if podOwned(pod.index) or Ui.numAttr(Attr.Coins, 0) < pod.cost then
		return
	end
	local now = os.clock()
	if now - lastPodBuyAt < BUY_DEBOUNCE_SEC then
		return
	end
	lastPodBuyAt = now
	buyPod:FireServer(pod.index)
end

local function buildPods(buyPod: RemoteEvent): Ui.Panel
	local p = Ui.panel(
		"PodShop",
		"Glow Pods",
		20,
		Vector2.new(0.6, 0.7),
		Vector2.new(300, 280),
		Vector2.new(560, 520)
	)
	local hint = Ui.label({
		Name = "Hint",
		Text = "Stand in a pod you own to earn MP every second.",
		Size = UDim2.fromScale(1, 0.1),
		TextColor3 = Theme.textDim,
		Parent = p.body,
	})
	Ui.textLimit(20).Parent = hint
	local list = Ui.scrollList({
		Name = "List",
		Position = UDim2.fromScale(0, 0.12),
		Size = UDim2.fromScale(1, 0.88),
		Parent = p.body,
	})
	for _, pod in GameData.pods() do
		if pod.worldId ~= 1 then
			continue -- World 2 pods ship with Update 1 (D-034)
		end
		local rowFrame = Ui.new("Frame", {
			Name = `Pod{pod.index}`,
			LayoutOrder = pod.index,
			BackgroundColor3 = Theme.panelLight,
			Size = UDim2.new(1, -10, 0, POD_ROW_PX),
			Parent = list,
		}, { Ui.corner(0.2) })
		local name = Ui.label({
			Name = "Name",
			Text = pod.name,
			TextXAlignment = Enum.TextXAlignment.Left,
			Position = UDim2.fromScale(0.04, 0.08),
			Size = UDim2.fromScale(0.56, 0.48),
			Parent = rowFrame,
		})
		Ui.textLimit(24).Parent = name
		local info = Ui.label({
			Name = "Info",
			Text = `+{NumberFormat.abbreviate(pod.mpPerSec)} MP/s (x your multiplier)`,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextColor3 = Theme.accent,
			Position = UDim2.fromScale(0.04, 0.56),
			Size = UDim2.fromScale(0.56, 0.36),
			Parent = rowFrame,
		})
		Ui.textLimit(18).Parent = info
		local buy = Ui.button({
			Name = "Buy",
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -6, 0.5, 0),
			Size = UDim2.new(0.36, 0, 1, -12),
			Parent = rowFrame,
		})
		Ui.textLimit(22).Parent = buy
		buy.Activated:Connect(function()
			onBuyPod(buyPod, pod)
		end)
		table.insert(podRows, { pod = pod, buy = buy })
	end
	local notice = Ui.label({
		Name = "World2Notice",
		Text = WORLD2_NOTICE,
		LayoutOrder = 1000,
		TextColor3 = Theme.textDim,
		Size = UDim2.new(1, -10, 0, 44),
		Parent = list,
	})
	Ui.textLimit(20).Parent = notice
	return p
end

local function openPods()
	local p = podPanel
	if p == nil or not Ui.boolAttr(Attr.DataLoaded) then
		return
	end
	p.root.Visible = true
	refreshPods()
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

	local pods = buildPods(Remotes.getEvent("BuyPod"))
	podPanel = pods

	-- One panel at a time: opening any other panel closes these two.
	UiEvents.OpenPanel:Connect(function(name: string)
		if name == "Tools" then
			pods.root.Visible = false
			open()
		elseif name == "Pods" then
			p.root.Visible = false
			openPods()
		else
			p.root.Visible = false
			pods.root.Visible = false
		end
	end)
	ProximityPromptService.PromptTriggered:Connect(function(prompt: ProximityPrompt, who: Player)
		if who == player and GameData.isShopPrompt(prompt, "Tools") then
			UiEvents.fireOpenPanel("Tools") -- closes other panels, then opens this one
		end
	end)

	for _, name in { Attr.ToolIndex, Attr.Coins, Attr.World2Unlocked } do
		player:GetAttributeChangedSignal(name):Connect(refresh)
	end
	for _, name in { Attr.PodsMask, Attr.Coins, Attr.CurrentPod } do
		player:GetAttributeChangedSignal(name):Connect(refreshPods)
	end
end

return ShopController
