--!strict
-- TapService (architecture 1b #14, layer L2). Owned by gameplay-programmer.
-- Handles `TapBatch` (the client sends a tap COUNT, never an amount) and owns `addMp`, the only code that adds MP.
-- Taps pass a per-player bucket at TAP_CAP_PER_SEC minus the player's AutoTapRate (burst = 1 s); extra taps are
-- dropped silently. MP per tap = ToolPower x M, both read on the server. Sole writer of the `MpPerTap` attribute.
-- While a duel runs, DuelService installs a tap sink: manual taps go to the sink (it applies the duel clamp,
-- architecture 4c) and earn no PvE MP; auto taps are ignored.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Deps = require(script.Parent.Util.Deps)
local EconomyConfig = require(ReplicatedStorage.Shared.Gameplay.EconomyConfig)
local Guard = require(script.Parent.Util.Guard)
local MultiplierService = require(script.Parent.MultiplierService)
local RankService = require(script.Parent.RankService)
local RateLimit = require(ReplicatedStorage.Shared.Contracts.RateLimit)
local ShopService = require(script.Parent.ShopService)
local TapBucket = require(script.Parent.Util.TapBucket)
local Types = require(ReplicatedStorage.Shared.Contracts.Types)

local Attr = Types.PlayerAttr

type TapSink = (accepted: number) -> ()

local TapService = {}

local buckets: { [Player]: TapBucket.Bucket } = {}
local sinks: { [Player]: TapSink } = {}
local firstTapSent: { [Player]: boolean } = {}

-- Manual tap rate left after auto-tap, so manual + auto never exceeds TAP_CAP_PER_SEC.
local function manualRate(player: Player): number
	local auto = Guard.clampFinite(player:GetAttribute(Attr.AutoTapRate), 0, EconomyConfig.TAP_CAP_PER_SEC, 0)
	return EconomyConfig.TAP_CAP_PER_SEC - auto
end

local function mpPerTap(player: Player): number
	local value = ShopService.getToolPower(player) * MultiplierService.getMpMultiplier(player)
	if player:GetAttribute(Attr.MpPerTap) ~= value then
		player:SetAttribute(Attr.MpPerTap, value)
	end
	return value
end

-- The only MP writer. Adds `amount` to mp and lifetimeMp, then lets RankService check for a rank-up.
-- Server callers only (TapService, IdleService). Non-finite or non-positive amounts are ignored.
-- `_source` is kept for later telemetry; MP gains are never logged per tap (architecture 5).
function TapService.addMp(player: Player, amount: number, _source: Types.MpSource)
	if not Guard.isFinite(amount) or amount <= 0 then
		return
	end
	local lifetime: number? = nil
	local ok = Deps.data().update(player, function(data)
		data.mp += amount
		data.lifetimeMp += amount
		lifetime = data.lifetimeMp
	end)
	if ok and lifetime then
		RankService.onLifetimeMp(player, lifetime)
	end
end

-- Credits `count` taps (1..TAP_BATCH_MAX). Returns how many were accepted for PvE MP.
-- "Manual" taps pass the per-player bucket; "Auto" taps come from IdleService at the server-set AutoTapRate.
function TapService.addTaps(player: Player, count: number, source: "Manual" | "Auto"): number
	if not Deps.data().isLoaded(player) or not Guard.isIntInRange(count, 1, EconomyConfig.TAP_BATCH_MAX) then
		return 0
	end
	local sink = sinks[player]
	if sink then
		if source == "Manual" then
			sink(count)
		end
		return 0
	end
	local accepted: number
	if source == "Manual" then
		local bucket = buckets[player]
		local now = os.clock()
		local rate = manualRate(player)
		local capacity = rate * EconomyConfig.TAP_BURST_SEC
		if bucket == nil then
			bucket = TapBucket.new(capacity, now)
			buckets[player] = bucket
		end
		accepted = TapBucket.take(bucket, count, rate, capacity, now)
	elseif source == "Auto" then
		accepted = math.min(count, EconomyConfig.TAP_CAP_PER_SEC)
	else
		return 0
	end
	if accepted <= 0 then
		return 0
	end
	TapService.addMp(player, accepted * mpPerTap(player), if source == "Manual" then "Tap" else "AutoTap")
	if not firstTapSent[player] and source == "Manual" then
		firstTapSent[player] = true
		Deps.funnel(player, "FirstTap")
	end
	return accepted
end

-- DuelService routes a duelist's taps while a duel runs; pass nil to restore PvE taps.
function TapService.setTapSink(player: Player, sink: TapSink?)
	sinks[player] = sink
end

function TapService.Init() end

function TapService.Start()
	local dataApi = Deps.data()

	RateLimit.connect("TapBatch", function(player: Player, count: any)
		if not dataApi.isLoaded(player) then
			return
		end
		if not Guard.isIntInRange(count, 1, EconomyConfig.TAP_BATCH_MAX) then
			return
		end
		TapService.addTaps(player, count, "Manual")
	end)

	local function refreshAttr(player: Player)
		if dataApi.isLoaded(player) then
			mpPerTap(player)
		end
	end
	dataApi.ProfileLoaded:Connect(refreshAttr)
	ShopService.ToolBought:Connect(refreshAttr)
	MultiplierService.Changed:Connect(refreshAttr)
	for _, player in Players:GetPlayers() do
		refreshAttr(player)
	end

	Players.PlayerRemoving:Connect(function(player: Player)
		buckets[player] = nil
		sinks[player] = nil
		firstTapSent[player] = nil
	end)
end

return TapService
