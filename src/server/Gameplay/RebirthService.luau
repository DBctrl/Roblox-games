--!strict
-- RebirthService (architecture 1b #15, layer L2). Owned by gameplay-programmer.
-- `RequestRebirth()` takes no arguments (extra ones are ignored). The cost is computed here from the profile:
-- 15,000 x 3^(n-1) coins (EconomyConfig.rebirthCost). There is no paid skip anywhere (GDD 4.5 rev 1).
-- One DataService.update re-checks the coins and resets MP, coins and the tool; pods, pets, rank, lifetime MP,
-- paid items, codes and settings are kept. Each rebirth adds +0.5 to RebirthMult and +10% coins, which
-- MultiplierService computes from `rebirths` on refresh.
-- Lean v1 (D-034): no World 2 unlock here; `world2Unlocked` is never touched, so World2Unlocked stays false
-- (Rebirth 3 unlock = T-091, Update 1). Sole writer of the `RebirthCost` attribute.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ActivityService = require(script.Parent.ActivityService)
local Deps = require(script.Parent.Util.Deps)
local EconomyConfig = require(ReplicatedStorage.Shared.Gameplay.EconomyConfig)
local MultiplierService = require(script.Parent.MultiplierService)
local NumberFormat = require(ReplicatedStorage.Shared.Contracts.NumberFormat)
local RateLimit = require(ReplicatedStorage.Shared.Contracts.RateLimit)
local Remotes = require(ReplicatedStorage.Shared.Contracts.Remotes)
local ShopService = require(script.Parent.ShopService)
local Types = require(ReplicatedStorage.Shared.Contracts.Types)

local Attr = Types.PlayerAttr

local EFFECT_PER_SEC = 10 -- architecture 2 #18: PlayEffect <= 10/s per server

local rebirthedEvent = Instance.new("BindableEvent")

local RebirthService = {}
RebirthService.Rebirthed = rebirthedEvent.Event -- (player: Player, rebirths: number)

local notifyRemote: RemoteEvent? = nil
local effectRemote: RemoteEvent? = nil
local effectBucket = RateLimit.newBucket(EFFECT_PER_SEC, os.clock())

local function notify(player: Player, kind: Types.NotifyKind, text: string)
	if notifyRemote then
		local payload: Types.NotifyPayload = { kind = kind, text = text }
		notifyRemote:FireClient(player, payload)
	end
end

local function refreshAttributes(player: Player)
	local data = Deps.data().getData(player)
	if data == nil then
		return
	end
	local cost = EconomyConfig.rebirthCost(data.rebirths + 1)
	if player:GetAttribute(Attr.RebirthCost) ~= cost then
		player:SetAttribute(Attr.RebirthCost, cost)
	end
end

-- Coins needed for the player's next rebirth.
function RebirthService.getCost(player: Player): number
	local data = Deps.data().getData(player)
	return EconomyConfig.rebirthCost(if data then data.rebirths + 1 else 1)
end

-- Rebirths the player if they have the coins and are not in a duel. Never takes a skip or a price from anyone.
function RebirthService.tryRebirth(player: Player): (boolean, string?)
	local dataApi = Deps.data()
	local data = dataApi.getData(player)
	if data == nil then
		return false, "NotLoaded"
	end
	if Deps.inDuel(player, ActivityService.get(player)) then
		return false, "InDuel"
	end
	local cost = RebirthService.getCost(player)
	if data.coins < cost then
		return false, "NotEnoughCoins"
	end

	local rebirths: number? = nil
	dataApi.update(player, function(d)
		if d.coins < cost then
			return -- re-checked inside the update: the reset is all-or-nothing
		end
		d.coins = 0
		d.mp = 0
		d.toolIndex = 1
		d.rebirths += 1
		rebirths = d.rebirths
		-- Kept on purpose: podsMask, pets, pity, rank, lifetimeMp, entitlements, boosts, codes, settings,
		-- world2Unlocked (no World 2 unlock in v1, T-091).
	end)
	if rebirths == nil then
		return false, "NotEnoughCoins"
	end

	ShopService.refreshAttributes(player) -- ToolIndex back to 1 (CR-a)
	MultiplierService.refresh(player) -- RebirthMult and coin multiplier from the new count
	refreshAttributes(player)
	rebirthedEvent:Fire(player, rebirths)
	Deps.economy(player, "Sink", cost, "Rebirth")
	if rebirths == 1 then
		Deps.funnel(player, "FirstRebirth")
	end
	local mpText = NumberFormat.multiplier(EconomyConfig.rebirthMult(rebirths))
	local coinText = NumberFormat.multiplier(EconomyConfig.coinRebirthMult(rebirths))
	notify(player, "Success", `Rebirth {rebirths}! MP {mpText}, coins {coinText}`)
	if effectRemote and RateLimit.take(effectBucket, EFFECT_PER_SEC, EFFECT_PER_SEC, os.clock()) then
		local payload: Types.EffectPayload = { userId = player.UserId, rebirths = rebirths }
		effectRemote:FireAllClients("Rebirth" :: Types.EffectId, payload)
	end
	return true
end

function RebirthService.Init() end

function RebirthService.Start()
	notifyRemote = Remotes.getEvent("Notify")
	effectRemote = Remotes.getEvent("PlayEffect")
	local dataApi = Deps.data()

	-- No arguments are read: a client-sent "skip", cost or count is ignored by construction.
	RateLimit.connect("RequestRebirth", function(player: Player)
		if not dataApi.isLoaded(player) then
			return
		end
		local ok, reason = RebirthService.tryRebirth(player)
		if ok then
			return
		end
		if reason == "NotEnoughCoins" then
			notify(
				player,
				"Error",
				`Rebirth needs {NumberFormat.abbreviate(RebirthService.getCost(player))} coins`
			)
		elseif reason == "InDuel" then
			notify(player, "Error", "Finish your duel first")
		end
	end)

	dataApi.ProfileLoaded:Connect(refreshAttributes)
	for _, player in Players:GetPlayers() do
		if dataApi.isLoaded(player) then
			refreshAttributes(player)
		end
	end
end

return RebirthService
