--!strict
-- ShopService (architecture 1b #11, layer L1). Owned by gameplay-programmer.
-- Coin shop for tools and Glow Pods. Coins only: there is no Robux path to a tool or pod (GDD 8g).
-- The client sends only an index; cost, order and ownership are checked here, and coins move only through
-- DataService.trySpendCoins. Sole writer of the `ToolIndex` and `PodsMask` attributes.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Deps = require(script.Parent.Util.Deps)
local EconomyConfig = require(ReplicatedStorage.Shared.Gameplay.EconomyConfig)
local Guard = require(script.Parent.Util.Guard)
local NumberFormat = require(ReplicatedStorage.Shared.Contracts.NumberFormat)
local RateLimit = require(ReplicatedStorage.Shared.Contracts.RateLimit)
local Remotes = require(ReplicatedStorage.Shared.Contracts.Remotes)
local Types = require(ReplicatedStorage.Shared.Contracts.Types)

local Attr = Types.PlayerAttr

local toolBoughtEvent = Instance.new("BindableEvent")
local podBoughtEvent = Instance.new("BindableEvent")

local ShopService = {}
ShopService.ToolBought = toolBoughtEvent.Event -- (player: Player, toolIndex: number)
ShopService.PodBought = podBoughtEvent.Event -- (player: Player, podIndex: number)

local notifyRemote: RemoteEvent? = nil

local function worldUnlocked(data: Types.ProfileData, world: number): boolean
	return world == 1 or (world == 2 and data.world2Unlocked == true)
end

local function podBit(podIndex: number): number
	return bit32.lshift(1, podIndex) -- bit i = pod i owned (architecture 1e)
end

local function toolIndexOf(data: Types.ProfileData): number
	return math.floor(Guard.clampFinite(data.toolIndex, 1, #EconomyConfig.TOOLS, 1))
end

local function notify(player: Player, kind: Types.NotifyKind, text: string)
	if notifyRemote then
		local payload: Types.NotifyPayload = { kind = kind, text = text }
		notifyRemote:FireClient(player, payload)
	end
end

-- Writes ToolIndex and PodsMask from the profile. RebirthService calls this after its reset (sprint 2).
function ShopService.refreshAttributes(player: Player)
	local data = Deps.data().getData(player)
	if data == nil then
		return
	end
	player:SetAttribute(Attr.ToolIndex, toolIndexOf(data))
	player:SetAttribute(Attr.PodsMask, math.floor(Guard.clampFinite(data.podsMask, 0, 2 ^ 31, 0)))
end

-- MP per tap of the player's current tool (before M). 1 if the profile is not loaded.
function ShopService.getToolPower(player: Player): number
	local data = Deps.data().getData(player)
	if data == nil then
		return EconomyConfig.TOOLS[1].mpPerTap
	end
	return EconomyConfig.TOOLS[toolIndexOf(data)].mpPerTap
end

-- Buys tool `toolIndex`. Only the next tool (ToolIndex + 1), in an unlocked world, paid in coins.
function ShopService.tryBuyTool(player: Player, toolIndex: number): (boolean, string?)
	local dataApi = Deps.data()
	local data = dataApi.getData(player)
	if data == nil then
		return false, "NotLoaded"
	end
	if not Guard.isIntInRange(toolIndex, 1, #EconomyConfig.TOOLS) then
		return false, "BadArgs"
	end
	if toolIndex ~= toolIndexOf(data) + 1 then
		return false, "NotNext"
	end
	local tool = EconomyConfig.TOOLS[toolIndex]
	if not worldUnlocked(data, tool.world) then
		return false, "WorldLocked"
	end
	if tool.cost > 0 and not dataApi.trySpendCoins(player, tool.cost, "Tool") then
		return false, "NotEnoughCoins"
	end
	dataApi.update(player, function(d)
		d.toolIndex = toolIndex
	end)
	player:SetAttribute(Attr.ToolIndex, toolIndex)
	toolBoughtEvent:Fire(player, toolIndex)
	Deps.economy(player, "Sink", tool.cost, "Tool")
	Deps.funnel(player, "FirstUpgrade")
	return true
end

-- Buys Glow Pod `podIndex` (1..7): not owned yet, world unlocked, paid in coins.
function ShopService.tryBuyPod(player: Player, podIndex: number): (boolean, string?)
	local dataApi = Deps.data()
	local data = dataApi.getData(player)
	if data == nil then
		return false, "NotLoaded"
	end
	if not Guard.isIntInRange(podIndex, 1, #EconomyConfig.PODS) then
		return false, "BadArgs"
	end
	local mask = math.floor(Guard.clampFinite(data.podsMask, 0, 2 ^ 31, 0))
	if bit32.btest(mask, podBit(podIndex)) then
		return false, "Owned"
	end
	local pod = EconomyConfig.PODS[podIndex]
	if not worldUnlocked(data, pod.world) then
		return false, "WorldLocked"
	end
	if not dataApi.trySpendCoins(player, pod.cost, "Pod") then
		return false, "NotEnoughCoins"
	end
	local newMask = bit32.bor(mask, podBit(podIndex))
	dataApi.update(player, function(d)
		d.podsMask = newMask
	end)
	player:SetAttribute(Attr.PodsMask, newMask)
	podBoughtEvent:Fire(player, podIndex)
	Deps.economy(player, "Sink", pod.cost, "Pod")
	Deps.funnel(player, "FirstPod")
	return true
end

local function reasonText(reason: string?, cost: number): string?
	if reason == "NotEnoughCoins" then
		return `Not enough coins (need {NumberFormat.abbreviate(cost)})`
	elseif reason == "WorldLocked" then
		return "Unlocks in World 2"
	end
	return nil -- other failures are silent (stale UI or a forged call)
end

function ShopService.Init() end

function ShopService.Start()
	notifyRemote = Remotes.getEvent("Notify")
	local dataApi = Deps.data()

	RateLimit.connect("BuyTool", function(player: Player, toolIndex: any)
		if not dataApi.isLoaded(player) or not Guard.isIntInRange(toolIndex, 1, #EconomyConfig.TOOLS) then
			return
		end
		local ok, reason = ShopService.tryBuyTool(player, toolIndex)
		local tool = EconomyConfig.TOOLS[toolIndex]
		if ok then
			notify(player, "Success", `Got {tool.name}!`)
		else
			local text = reasonText(reason, tool.cost)
			if text then
				notify(player, "Error", text)
			end
		end
	end)

	RateLimit.connect("BuyPod", function(player: Player, podIndex: any)
		if not dataApi.isLoaded(player) or not Guard.isIntInRange(podIndex, 1, #EconomyConfig.PODS) then
			return
		end
		local ok, reason = ShopService.tryBuyPod(player, podIndex)
		local pod = EconomyConfig.PODS[podIndex]
		if ok then
			notify(player, "Success", `Unlocked {pod.name}!`)
		else
			local text = reasonText(reason, pod.cost)
			if text then
				notify(player, "Error", text)
			end
		end
	end)

	dataApi.ProfileLoaded:Connect(ShopService.refreshAttributes)
	for _, player in Players:GetPlayers() do
		if dataApi.isLoaded(player) then
			ShopService.refreshAttributes(player)
		end
	end
end

return ShopService
