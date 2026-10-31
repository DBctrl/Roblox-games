--!strict
-- IdleService (architecture 1b #16, layer L3). Owned by gameplay-programmer.
-- ONE 1 Hz loop for all players (architecture 7), no per-player loops:
--   * Pod MP/s: only the pod the player stands in counts (ZoneService.getPod), only if owned and its world is
--     unlocked. MP = PodRate x M x elapsed, added through TapService.addMp (the only MP writer).
--   * Auto-Tap: free 3 taps/s from Rank 3, or 6 taps/s with the paid Auto Clicker (ownership read from the
--     Monetization API or the profile; never decided here). Credited through TapService.addTaps("Auto").
--     TapService gives manual taps TAP_CAP_PER_SEC minus AutoTapRate, so manual + auto never exceeds 12/s.
--   * Auto-Mog: free from Rebirth 1 (no paid early unlock). Every 5 s it starts a fight against the strongest
--     beatable boss in the current world through BossService.tryFight(auto = true), even while in a pod.
-- Auto-Tap and Auto-Mog follow the player's SettingAutoTap / SettingAutoMog and pause in duels.
-- No remotes: nothing here takes client input. Sole writer of IdleMpPerSec, AutoTapRate, AutoTapUnlocked and
-- AutoMogUnlocked (DataService's SetSetting reads AutoTapUnlocked, CR-3).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ActivityService = require(script.Parent.ActivityService)
local BossService = require(script.Parent.BossService)
local Deps = require(script.Parent.Util.Deps)
local EconomyConfig = require(ReplicatedStorage.Shared.Gameplay.EconomyConfig)
local Guard = require(script.Parent.Util.Guard)
local MultiplierService = require(script.Parent.MultiplierService)
local RankService = require(script.Parent.RankService)
local TapService = require(script.Parent.TapService)
local Types = require(ReplicatedStorage.Shared.Contracts.Types)

local Attr = Types.PlayerAttr

type ProfileData = Types.ProfileData

local TICK_SEC = 1 -- architecture 7: one 1 Hz loop
local MAX_STEP_SEC = 2 -- a long server hitch never pays more than 2 s at once

type State = {
	tapCarry: number, -- fractional auto taps carried to the next tick
	nextMogAt: number, -- os.clock() time of the next Auto-Mog attempt
}

local IdleService = {}

local states: { [Player]: State } = {}
local loop: thread? = nil

local function setAttr(player: Player, name: string, value: any)
	if player:GetAttribute(name) ~= value then
		player:SetAttribute(name, value)
	end
end

local function ownsAutoClicker(player: Player, data: ProfileData): boolean
	local monetization = Deps.monetization()
	local owns = monetization and monetization.owns
	if owns then
		return owns(player, "AutoClicker")
	end
	return data.entitlements.autoClicker == true
end

local function podOwned(data: ProfileData, podIndex: number): boolean
	local mask = math.floor(Guard.clampFinite(data.podsMask, 0, 2 ^ 31, 0))
	return bit32.btest(mask, bit32.lshift(1, podIndex)) -- bit i = pod i (architecture 1e)
end

local function worldUnlocked(data: ProfileData, world: number): boolean
	return world == 1 or (world == 2 and data.world2Unlocked == true)
end

-- Base MP/s of the pod the player stands in and owns (0 if none).
local function podRate(player: Player, data: ProfileData): number
	local zone = Deps.zone()
	local getPod = zone and zone.getPod
	if getPod == nil then
		return 0
	end
	local podIndex = getPod(player)
	if not Guard.isIntInRange(podIndex, 1, #EconomyConfig.PODS) or not podOwned(data, podIndex) then
		return 0
	end
	local pod = EconomyConfig.PODS[podIndex]
	return if worldUnlocked(data, pod.world) then pod.mpPerSec else 0
end

local function tickPlayer(player: Player, state: State, dt: number, now: number)
	local dataApi = Deps.data()
	local data = dataApi.getData(player)
	if data == nil then
		return
	end
	local inDuel = Deps.inDuel(player, ActivityService.get(player))

	-- Unlocks (free progression only; Auto Clicker ownership comes from the Monetization/Data API).
	local clicker = ownsAutoClicker(player, data)
	local autoTapUnlocked = clicker or RankService.getRank(player) >= EconomyConfig.AUTO_TAP_FREE_RANK
	local autoMogUnlocked = data.rebirths >= EconomyConfig.AUTO_MOG_REBIRTHS
	setAttr(player, Attr.AutoTapUnlocked, autoTapUnlocked)
	setAttr(player, Attr.AutoMogUnlocked, autoMogUnlocked)

	-- Pod MP/s (only the pod the player stands in).
	local m = MultiplierService.getMpMultiplier(player)
	local idleRate = if inDuel then 0 else podRate(player, data) * m
	setAttr(player, Attr.IdleMpPerSec, idleRate)
	if idleRate > 0 then
		TapService.addMp(player, idleRate * dt, "Pod")
	end

	-- Auto-Tap. The rate is published first so TapService trims the manual cap to 12 - rate.
	local tapRate = 0
	if autoTapUnlocked and not inDuel and dataApi.getSetting(player, "AutoTap") then
		tapRate = if clicker then EconomyConfig.AUTO_CLICKER_RATE else EconomyConfig.AUTO_TAP_FREE_RATE
		tapRate = math.min(tapRate, EconomyConfig.TAP_CAP_PER_SEC)
	end
	setAttr(player, Attr.AutoTapRate, tapRate)
	if tapRate > 0 then
		state.tapCarry += tapRate * dt
		local taps = math.min(math.floor(state.tapCarry), EconomyConfig.TAP_BATCH_MAX)
		state.tapCarry = math.clamp(state.tapCarry - taps, 0, 1)
		if taps > 0 then
			TapService.addTaps(player, taps, "Auto")
		end
	else
		state.tapCarry = 0
	end

	-- Auto-Mog: refight the best beatable boss every AUTO_MOG_INTERVAL_SEC.
	if
		autoMogUnlocked
		and not inDuel
		and now >= state.nextMogAt
		and dataApi.getSetting(player, "AutoMog")
	then
		if ActivityService.get(player) == "Idle" then
			local bossId = BossService.bestBeatable(player)
			if bossId then
				BossService.tryFight(player, bossId, true)
			end
			state.nextMogAt = now + EconomyConfig.AUTO_MOG_INTERVAL_SEC
		end
	end
end

local function runLoop()
	local last = os.clock()
	while true do
		task.wait(TICK_SEC)
		local now = os.clock()
		local dt = math.clamp(now - last, 0, MAX_STEP_SEC)
		last = now
		for player, state in states do
			if player.Parent == Players then
				-- One player's error must not stop the loop for everyone.
				local ok, err = pcall(tickPlayer, player, state, dt, now)
				if not ok then
					warn(`[IdleService] tick failed for {player.UserId}: {err}`)
				end
			end
		end
	end
end

local function onLoaded(player: Player)
	if states[player] == nil then
		states[player] = { tapCarry = 0, nextMogAt = os.clock() + EconomyConfig.AUTO_MOG_INTERVAL_SEC }
	end
end

function IdleService.Init() end

function IdleService.Start()
	local dataApi = Deps.data()
	dataApi.ProfileLoaded:Connect(onLoaded)
	Players.PlayerRemoving:Connect(function(player: Player)
		states[player] = nil
	end)
	for _, player in Players:GetPlayers() do
		if dataApi.isLoaded(player) then
			onLoaded(player)
		end
	end
	if loop == nil then
		loop = task.spawn(runLoop)
	end
end

return IdleService
