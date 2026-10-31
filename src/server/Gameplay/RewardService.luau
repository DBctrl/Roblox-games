--!strict
-- RewardService (architecture 1b #19, layer L3). Owned by gameplay-programmer.
-- The free 7-day daily calendar (GDD 10): `ClaimDailyReward` takes no arguments; the day, streak and reward are all
-- computed on the server from UTC days (os.time()). Missing a day restarts at Day 1. Rewards come from
-- EconomyConfig.DAILY_REWARDS only: no paid item changes a daily coin or egg reward. VIP adds only
-- DAILY_VIP_HYPE_SEC of Hype Snack per claim (ownership read from the Monetization API, else the profile).
-- Sole writer of DailyStreak, DailyClaimable and DailyNextClaimUnix, and of profile.daily.
-- Codes (`RedeemCode`) are Update 2 (T-074, D-034): no handler in v1, so every RedeemCode call is dropped.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BossService = require(script.Parent.BossService)
local DailyMath = require(script.Parent.Util.DailyMath)
local Deps = require(script.Parent.Util.Deps)
local EconomyConfig = require(ReplicatedStorage.Shared.Gameplay.EconomyConfig)
local MultiplierService = require(script.Parent.MultiplierService)
local NumberFormat = require(ReplicatedStorage.Shared.Contracts.NumberFormat)
local PetService = require(script.Parent.PetService)
local RateLimit = require(ReplicatedStorage.Shared.Contracts.RateLimit)
local Remotes = require(ReplicatedStorage.Shared.Contracts.Remotes)
local Types = require(ReplicatedStorage.Shared.Contracts.Types)

local Attr = Types.PlayerAttr

type ProfileData = Types.ProfileData

local RewardService = {}

local notifyRemote: RemoteEvent? = nil
local effectRemote: RemoteEvent? = nil
local dayTimer: thread? = nil

local function setAttr(player: Player, name: string, value: any)
	if player.Parent == Players and player:GetAttribute(name) ~= value then
		player:SetAttribute(name, value)
	end
end

local function notify(player: Player, kind: Types.NotifyKind, text: string)
	if notifyRemote then
		local payload: Types.NotifyPayload = { kind = kind, text = text }
		notifyRemote:FireClient(player, payload)
	end
end

local function today(): number
	return DailyMath.utcDay(os.time())
end

local function hasVip(player: Player, data: ProfileData): boolean
	local monetization = Deps.monetization()
	local fn = monetization and monetization.hasVip
	if fn then
		return fn(player)
	end
	return data.entitlements.vip == true
end

-- First coin egg (EGG_IDS order) of the best unlocked world that has one: Basic Egg in v1 (Neon is T-090).
local function freeHatchEgg(data: ProfileData): Types.EggId
	local best: string = "BasicEgg"
	local bestWorld = 0
	for _, eggId in EconomyConfig.EGG_IDS do
		local egg = EconomyConfig.EGGS[eggId]
		local unlocked = egg.world == 1 or (egg.world == 2 and data.world2Unlocked == true)
		if egg.currency == "Coins" and unlocked and egg.world > bestWorld then
			best = eggId
			bestWorld = egg.world
		end
	end
	return best :: Types.EggId
end

local function refreshAttributes(player: Player)
	local data = Deps.data().getData(player)
	if data == nil then
		return
	end
	local day = today()
	local claimable = DailyMath.claim(data.daily.lastClaimDay, data.daily.streak, day)
	setAttr(player, Attr.DailyStreak, DailyMath.shownStreak(data.daily.lastClaimDay, data.daily.streak, day))
	setAttr(player, Attr.DailyClaimable, claimable)
	setAttr(player, Attr.DailyNextClaimUnix, if claimable then 0 else DailyMath.dayStart(day + 1))
end

-- Claims today's reward. All checks are server-side; returns ok, reason ("NotLoaded", "AlreadyClaimed", "NoSlot").
function RewardService.claim(player: Player): (boolean, string?)
	local dataApi = Deps.data()
	local data = dataApi.getData(player)
	if data == nil then
		return false, "NotLoaded"
	end
	local day = today()
	local ok, streak = DailyMath.claim(data.daily.lastClaimDay, data.daily.streak, day)
	if not ok then
		return false, "AlreadyClaimed"
	end
	local reward = EconomyConfig.DAILY_REWARDS[streak]
	if reward.freeHatch and PetService.freeSlots(player) < 1 then
		return false, "NoSlot" -- nothing claimed: the player can make room and claim later today
	end

	-- 1) Mark the day claimed (re-checked inside the update, so two claims in one day cannot both pass).
	local claimed = false
	dataApi.update(player, function(d)
		local again, s = DailyMath.claim(d.daily.lastClaimDay, d.daily.streak, day)
		if again and s == streak then
			d.daily.lastClaimDay = day
			d.daily.streak = streak
			if reward.cosmetic then
				d.entitlements.cosmetics[reward.cosmetic] = true
			end
			claimed = true
		end
	end)
	if not claimed then
		return false, "AlreadyClaimed"
	end

	-- 2) Pay the day's free reward.
	local coins = 0
	if reward.coinSec then
		coins = math.floor(reward.coinSec * BossService.bestCoinsPerSec(player))
		if coins > 0 and dataApi.addCoins(player, coins, "Daily") > 0 then
			Deps.economy(player, "Source", coins, "Daily")
		else
			coins = 0
		end
	end
	if reward.hypeSec then
		MultiplierService.addBoost(player, "Hype", reward.hypeSec)
	end
	if reward.coinSnackSec then
		MultiplierService.addBoost(player, "Coin", reward.coinSnackSec)
	end
	if reward.freeHatch then
		PetService.grantEgg(player, freeHatchEgg(data), 1)
	end
	-- VIP perk: Hype Snack time only, never coins or eggs (GDD 8, 10).
	if hasVip(player, data) then
		MultiplierService.addBoost(player, "Hype", EconomyConfig.DAILY_VIP_HYPE_SEC)
	end

	refreshAttributes(player)
	if effectRemote then
		local payload: Types.EffectPayload = { amount = coins }
		effectRemote:FireClient(player, "DailyReward", payload)
	end
	notify(
		player,
		"Success",
		if coins > 0
			then `Day {streak} reward: +{NumberFormat.abbreviate(coins)} coins!`
			else `Day {streak} reward claimed!`
	)
	return true, nil
end

-- One server timer for all players: at each UTC midnight every calendar becomes claimable again.
local function scheduleDayRollover()
	if dayTimer then
		task.cancel(dayTimer)
	end
	local wait = DailyMath.dayStart(today() + 1) - os.time() + 1
	dayTimer = task.delay(math.max(1, wait), function()
		dayTimer = nil
		for _, player in Players:GetPlayers() do
			refreshAttributes(player)
		end
		scheduleDayRollover()
	end)
end

function RewardService.Init() end

function RewardService.Start()
	notifyRemote = Remotes.getEvent("Notify")
	effectRemote = Remotes.getEvent("PlayEffect")
	local dataApi = Deps.data()

	RateLimit.connect("ClaimDailyReward", function(player: Player)
		if not dataApi.isLoaded(player) then
			return
		end
		local ok, reason = RewardService.claim(player)
		if not ok and reason == "NoSlot" then
			notify(player, "Error", "Pet inventory full. Delete a pet to claim today's free hatch")
		end
	end)

	dataApi.ProfileLoaded:Connect(refreshAttributes)
	for _, player in Players:GetPlayers() do
		if dataApi.isLoaded(player) then
			refreshAttributes(player)
		end
	end
	scheduleDayRollover()
end

return RewardService
