--!strict
-- MultiplierService (architecture 1b #9 and 4a, layer L0). Owned by gameplay-programmer.
-- Computes M (MP multiplier) and the coin multiplier on events only (load, boost start/end, refresh calls from
-- pets/rebirth, EntitlementsChanged), never per tap. TapService/IdleService/BossService read the cached values.
-- Sole writer of the Multiplier, CoinMultiplier, HypeEndsAt, CoinSnackEndsAt and SpeedEndsAt attributes.
--
-- Timed boosts tick only while the player is online: `profile.boosts.*Sec` holds the seconds left, and the time
-- used is written back on every refresh and when the session ends. Each boost caps at 2 h (EconomyConfig).
-- Ownership (paid tier, VIP) is read from MonetizationService when it exists (sprint 3), otherwise from the
-- profile entitlements through DataService. This service never decides a purchase.
-- Receipt grants (PaidTier, Boost) are registered in T-053 (sprint 3, owner price gate).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Deps = require(script.Parent.Util.Deps)
local EconomyConfig = require(ReplicatedStorage.Shared.Gameplay.EconomyConfig)
local Guard = require(script.Parent.Util.Guard)
local MultiplierMath = require(script.Parent.Util.MultiplierMath)
local Types = require(ReplicatedStorage.Shared.Contracts.Types)

local Attr = Types.PlayerAttr

type BoostKind = Types.BoostKind
type Boosts = { hypeSec: number, coinSec: number, speedSec: number }

local KINDS: { BoostKind } = { "Hype", "Coin", "Speed" }
local ENDS_ATTR: { [BoostKind]: string } = {
	Hype = Attr.HypeEndsAt,
	Coin = Attr.CoinSnackEndsAt,
	Speed = Attr.SpeedEndsAt,
}

local function rawSec(boosts: Boosts, kind: BoostKind): number
	return if kind == "Hype" then boosts.hypeSec elseif kind == "Coin" then boosts.coinSec else boosts.speedSec
end

-- Seconds left for `kind`; a corrupt (NaN, inf, negative) stored value counts as 0.
local function getSec(boosts: Boosts, kind: BoostKind): number
	local raw = rawSec(boosts, kind)
	if raw == math.huge then
		return 0
	end
	return Guard.clampFinite(raw, 0, math.huge, 0)
end

local function setSec(boosts: Boosts, kind: BoostKind, sec: number)
	if kind == "Hype" then
		boosts.hypeSec = sec
	elseif kind == "Coin" then
		boosts.coinSec = sec
	else
		boosts.speedSec = sec
	end
end

type State = {
	m: number,
	coinM: number,
	syncedAt: number, -- server time up to which boost use has been written to the profile
	active: { [BoostKind]: boolean }, -- boost had time left at the last sync (only these are charged)
	speedOn: boolean,
	timer: thread?, -- wakes the service when the next boost runs out
}

local changedEvent = Instance.new("BindableEvent")

local MultiplierService = {}
MultiplierService.Changed = changedEvent.Event -- (player: Player, m: number)

local states: { [Player]: State } = {}

local function now(): number
	return workspace:GetServerTimeNow()
end

-- Charges the boost time used since the last sync and returns the seconds left per kind.
-- Only boosts that were running at the last sync are charged, so time granted later is never charged for the gap.
local function consume(player: Player, state: State): { [BoostKind]: number }
	local t = now()
	local elapsed = math.max(0, t - state.syncedAt)
	state.syncedAt = t
	local left: { [BoostKind]: number } = { Hype = 0, Coin = 0, Speed = 0 }
	local data = Deps.data().getData(player)
	if data == nil then
		return left
	end
	local needsWrite = false
	for _, kind in KINDS do
		local sec = getSec(data.boosts, kind)
		left[kind] = if state.active[kind] then math.max(0, sec - elapsed) else sec
		if left[kind] ~= rawSec(data.boosts, kind) then
			needsWrite = true
		end
	end
	if needsWrite then
		Deps.data().update(player, function(d)
			for _, kind in KINDS do
				setSec(d.boosts, kind, left[kind])
			end
		end)
	end
	for _, kind in KINDS do
		state.active[kind] = left[kind] > 0
	end
	return left
end

local function setAttr(player: Player, name: string, value: number)
	if player:GetAttribute(name) ~= value then
		player:SetAttribute(name, value)
	end
end

local refresh: (player: Player) -> ()

local function schedule(player: Player, state: State, left: { [BoostKind]: number })
	if state.timer then
		task.cancel(state.timer)
		state.timer = nil
	end
	local soonest = math.huge
	for _, kind in KINDS do
		if left[kind] > 0 then
			soonest = math.min(soonest, left[kind])
		end
	end
	if soonest < math.huge then
		state.timer = task.delay(soonest + 0.1, function()
			state.timer = nil
			if states[player] == state then
				refresh(player)
			end
		end)
	end
end

-- Recomputes M, the coin multiplier and boost end times for `player`, and writes the attributes.
refresh = function(player: Player)
	local state = states[player]
	if state == nil then
		return
	end
	local data = Deps.data().getData(player)
	if data == nil then
		return
	end
	local left = consume(player, state)
	local t = state.syncedAt
	for _, kind in KINDS do
		setAttr(player, ENDS_ATTR[kind], if left[kind] > 0 then t + left[kind] else 0)
	end
	schedule(player, state, left)

	-- Ownership comes from the Monetization API when present, else from the profile (Data API).
	local monetization = Deps.monetization()
	local getPaidTier = monetization and monetization.getPaidTier
	local hasVip = monetization and monetization.hasVip
	local paidTier = if getPaidTier then getPaidTier(player) else data.entitlements.paidTier
	local vip = if hasVip then hasVip(player) else data.entitlements.vip == true

	local pets = Deps.pets()
	local getPetSum = pets and pets.getPetMultiplierSum
	local petSum = if getPetSum then getPetSum(player) else 0

	local m = MultiplierMath.mp(petSum, data.rebirths, paidTier, vip, left.Hype > 0)
	local coinM = MultiplierMath.coins(data.rebirths, left.Coin > 0)
	state.coinM = coinM
	setAttr(player, Attr.CoinMultiplier, coinM)
	setAttr(player, Attr.Multiplier, m)
	if m ~= state.m then
		state.m = m
		changedEvent:Fire(player, m)
	end

	local speedOn = left.Speed > 0
	if speedOn ~= state.speedOn then
		state.speedOn = speedOn
		local character = Deps.character()
		local setSpeed = character and character.setSpeedMultiplier
		if setSpeed then
			setSpeed(player, if speedOn then EconomyConfig.SPEED_WALK_MULT else 1)
		end
	end
end

-- Writes the last boost use into the profile and drops the player's state. Safe to call twice.
local function finalize(player: Player)
	local state = states[player]
	if state == nil then
		return
	end
	consume(player, state)
	if state.timer then
		task.cancel(state.timer)
		state.timer = nil
	end
	states[player] = nil
end

local function onLoaded(player: Player)
	if states[player] then
		return
	end
	states[player] = {
		m = 0, -- forces a Changed signal on the first refresh
		coinM = 1,
		syncedAt = now(),
		active = { Hype = false, Coin = false, Speed = false },
		speedOn = false,
		timer = nil,
	}
	refresh(player)
end

-- Public API -----------------------------------------------------------------------------------------------

function MultiplierService.getMpMultiplier(player: Player): number
	local state = states[player]
	return if state and state.m >= 1 then state.m else 1
end

function MultiplierService.getCoinMultiplier(player: Player): number
	local state = states[player]
	return if state then state.coinM else 1
end

function MultiplierService.refresh(player: Player)
	refresh(player)
end

-- Adds boost time (server callers only: daily, codes, events). Stops at the 2 h cap; never removes time.
function MultiplierService.addBoost(player: Player, kind: BoostKind, seconds: number)
	local state = states[player]
	if state == nil or ENDS_ATTR[kind] == nil or not Guard.isFinite(seconds) or seconds <= 0 then
		return
	end
	consume(player, state)
	Deps.data().update(player, function(data)
		local current = getSec(data.boosts, kind)
		if current < EconomyConfig.BOOST_CAP_SEC then
			setSec(data.boosts, kind, math.min(EconomyConfig.BOOST_CAP_SEC, current + seconds))
		end
	end)
	refresh(player)
end

function MultiplierService.Init() end

function MultiplierService.Start()
	local data = Deps.data()
	data.ProfileLoaded:Connect(onLoaded)
	data.ProfileReleasing:Connect(finalize)
	Players.PlayerRemoving:Connect(finalize)
	local monetization = Deps.monetization()
	if monetization and monetization.EntitlementsChanged then
		monetization.EntitlementsChanged:Connect(refresh)
	end
	for _, player in Players:GetPlayers() do
		if data.isLoaded(player) then
			onLoaded(player)
		end
	end
end

return MultiplierService
