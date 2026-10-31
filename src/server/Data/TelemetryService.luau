--!strict
-- TelemetryService: funnel, economy, custom and progression analytics. Owned by systems-programmer.
-- Contract: architecture 1b #5 and section 5, GDD 10 "Analytics events", legal 5.3 (UserId only, no free text).
--
-- * Thin wrapper over Roblox AnalyticsService. Every call is pcall-wrapped and looked up by name, so a missing
--   or renamed method only warns once and never breaks gameplay. TODO(verify-api): T-002 confirms the method
--   names and parameter order on the Mac (LogOnboardingFunnelStepEvent, LogEconomyEvent, LogCustomEvent,
--   LogProgressionEvent) and the Enum.AnalyticsEconomyFlowType / AnalyticsEconomyTransactionType /
--   AnalyticsProgressionType values used below.
-- * Events are keyed by the Player (UserId) only. No names, chat or other free text, and no custom fields.
-- * Funnel steps are deduped per profile through `profile.milestones` (written through DataService.update) and
--   logged once ever, plus a custom `TimeTo<Step>` event (seconds since first join).
-- * Budget: at most 1 event per 5 s on average per player (token bucket, rate 0.2/s, burst 10). Never per tap.
--   Economy events are summed per (flow, reason) and flushed every 60 s by one loop for all players, so a boss
--   win every 4 s costs nothing extra. An entry that finds the bucket empty waits for the next flush.
--   Funnel steps (9 per lifetime), progression (rank-ups, rebirths) and the leave flush are rare by design, so
--   they always send and spend a token if one is there.
-- * Progression and two funnel steps come from attributes, so no Gameplay call is needed for them:
--   `Rank` up -> progression "Rank"; `Rebirths` up -> progression "Rebirth" + funnel FirstRebirth;
--   `TutorialDone` true -> funnel TutorialDone; profile loaded -> funnel Spawn; leave -> custom SessionLength.
-- * Coin economy is logged by the callers that move coins (ShopService, BossService, PetService, RebirthService,
--   RewardService, DuelService via TelemetryService.economy), not inside DataService.addCoins/trySpendCoins, so
--   nothing is counted twice. Anything that changes coins inside a raw DataService.update must log it itself.

local AnalyticsService = game:GetService("AnalyticsService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DataService = require(script.Parent.DataService)
local RateLimit = require(ReplicatedStorage.Shared.Contracts.RateLimit)
local Types = require(ReplicatedStorage.Shared.Contracts.Types)

local Attr = Types.PlayerAttr

local BUCKET_RATE = 0.2 -- events per second (1 per 5 s average)
local BUCKET_BURST = 10
local ECONOMY_FLUSH_SEC = 60
local CURRENCY = "Coins"

-- Onboarding funnel order (architecture 5). The index is the funnel step number sent to Roblox.
local FUNNEL_ORDER: { Types.FunnelStep } = {
	"Spawn",
	"FirstTap",
	"FirstWin",
	"FirstUpgrade",
	"FirstPod",
	"FirstRankUp",
	"FirstEgg",
	"TutorialDone",
	"FirstRebirth",
}
local FUNNEL_INDEX: { [string]: number } = {}
for index, step in FUNNEL_ORDER do
	FUNNEL_INDEX[step] = index
end

local CUSTOM_EVENTS: { [string]: boolean } = {
	Purchase = true,
	DuelPlayed = true,
	DuelWon = true,
	DuelDraw = true,
	DuelForfeit = true,
	SessionLength = true,
}

-- CoinReason -> AnalyticsEconomyTransactionType name. Never a Robux source (GDD 8g).
local TRANSACTION_TYPE: { [string]: string } = {
	BossWin = "Gameplay",
	DuelReward = "Gameplay",
	Daily = "TimedReward",
	Code = "Gameplay",
	Tool = "Shop",
	Pod = "Shop",
	Egg = "Shop",
	Rebirth = "Shop",
}

type Pending = { flow: "Source" | "Sink", reason: string, amount: number }

type PlayerState = {
	bucket: RateLimit.Bucket,
	pending: { [string]: Pending },
	joinClock: number,
	rank: number,
	rebirths: number,
	connections: { RBXScriptConnection },
}

local TelemetryService = {}

local states: { [Player]: PlayerState } = {}
local warned: { [string]: boolean } = {}

local function isFinite(n: any): boolean
	return type(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge
end

local function warnOnce(key: string, message: string)
	if not warned[key] then
		warned[key] = true
		warn(`TelemetryService: {message}`)
	end
end

-- Enum item by name, or nil if this engine version doesn't have it (pcall: indexing a missing enum errors).
local function enumItem(enumName: string, itemName: string): EnumItem?
	local ok, item = pcall(function()
		return ((Enum :: any)[enumName] :: any)[itemName]
	end)
	if ok and typeof(item) == "EnumItem" then
		return item
	end
	warnOnce(`enum:{enumName}`, `Enum.{enumName}.{itemName} not found`)
	return nil
end

-- Calls AnalyticsService:<method>(...) safely. TODO(verify-api): method names and argument order (T-002).
local function send(method: string, ...: any)
	local service = AnalyticsService :: any
	local okIndex, fn = pcall(function()
		return service[method]
	end)
	if not okIndex or type(fn) ~= "function" then
		warnOnce(`missing:{method}`, `AnalyticsService.{method} is not available`)
		return
	end
	local ok, err = pcall(fn, service, ...)
	if not ok then
		warnOnce(`fail:{method}`, `{method} failed: {err}`)
	end
end

local function takeToken(state: PlayerState): boolean
	return RateLimit.take(state.bucket, BUCKET_RATE, BUCKET_BURST, os.clock())
end

local function liveState(player: Player): PlayerState?
	local state = states[player]
	if state == nil or not DataService.isLoaded(player) then
		return nil
	end
	return state
end

-- Sending ---------------------------------------------------------------------------------------------

local function sendEconomy(player: Player, entry: Pending)
	local data = DataService.getData(player)
	local balance = if data and isFinite(data.coins) then math.floor(data.coins) else 0
	local flow = enumItem("AnalyticsEconomyFlowType", entry.flow)
	if flow == nil then
		return
	end
	local transaction = TRANSACTION_TYPE[entry.reason] or "Gameplay"
	local transactionItem = enumItem("AnalyticsEconomyTransactionType", transaction)
	-- TODO(verify-api): LogEconomyEvent(player, flowType, currencyType, amount, endingBalance, transactionType,
	-- itemSku?). transactionType takes the enum item's Name string.
	send(
		"LogEconomyEvent",
		player,
		flow,
		CURRENCY,
		math.floor(entry.amount),
		balance,
		if transactionItem then transactionItem.Name else transaction,
		entry.reason
	)
end

local function sendProgression(player: Player, path: string, level: number)
	local complete = enumItem("AnalyticsProgressionType", "Complete")
	if complete == nil then
		return
	end
	-- TODO(verify-api): LogProgressionEvent(player, progressionPathName, status, level, levelName?).
	send("LogProgressionEvent", player, path, complete, level)
end

local function flushEconomy(player: Player, state: PlayerState, force: boolean)
	for key, entry in state.pending do
		if entry.amount < 1 then
			state.pending[key] = nil
		elseif force or takeToken(state) then
			state.pending[key] = nil
			sendEconomy(player, entry)
		end
	end
end

-- Public API (architecture 1b) ------------------------------------------------------------------------

-- Logs funnel `step` once per profile (deduped through profile.milestones), plus custom TimeTo<Step>.
-- Safe to call on every occurrence: repeats are a table lookup.
function TelemetryService.funnel(player: Player, step: Types.FunnelStep)
	local index = FUNNEL_INDEX[step :: any]
	local state = liveState(player)
	local data = DataService.getData(player)
	if index == nil or state == nil or data == nil or data.milestones[step] == true then
		return
	end
	local marked = false
	DataService.update(player, function(d)
		if d.milestones[step] ~= true then
			d.milestones[step] = true
			marked = true
		end
	end)
	if not marked then
		return
	end
	takeToken(state) -- spends a token if there is one; funnel steps are bounded (9 per lifetime)
	local first = data.stats.firstJoinUnix
	local seconds = if isFinite(first) and first > 0 then math.max(0, os.time() - first) else 0
	-- TODO(verify-api): LogOnboardingFunnelStepEvent(player, step: number, stepName: string?).
	send("LogOnboardingFunnelStepEvent", player, index, step)
	send("LogCustomEvent", player, `TimeTo{step}`, seconds)
end

-- Adds `amount` coins to this player's pending economy total for (flow, reason); flushed every 60 s and on
-- leave. Callers pass server-computed amounts only.
function TelemetryService.economy(
	player: Player,
	flow: "Source" | "Sink",
	amount: number,
	reason: Types.CoinReason
)
	local state = liveState(player)
	if state == nil or (flow ~= "Source" and flow ~= "Sink") or TRANSACTION_TYPE[reason :: any] == nil then
		return
	end
	if not isFinite(amount) or amount <= 0 then
		return
	end
	local key = `{flow}:{reason}`
	local entry = state.pending[key]
	if entry then
		entry.amount += amount
	else
		state.pending[key] = { flow = flow, reason = reason, amount = amount }
	end
end

-- Logs custom event `name` (one of T.CustomEvent) with an optional numeric value. Dropped when over budget.
function TelemetryService.custom(player: Player, name: Types.CustomEvent, value: number?)
	local state = liveState(player)
	if state == nil or not CUSTOM_EVENTS[name :: any] then
		return
	end
	if value ~= nil and not isFinite(value) then
		return
	end
	if not takeToken(state) then
		return
	end
	send("LogCustomEvent", player, name, value)
end

-- Lifecycle -------------------------------------------------------------------------------------------

local function numberAttr(player: Player, name: string): number
	local value = player:GetAttribute(name)
	return if isFinite(value) then value :: number else 0
end

local function onProfileLoaded(player: Player)
	if states[player] then
		return
	end
	local state: PlayerState = {
		bucket = RateLimit.newBucket(BUCKET_BURST, os.clock()),
		pending = {},
		joinClock = os.clock(),
		rank = numberAttr(player, Attr.Rank),
		rebirths = numberAttr(player, Attr.Rebirths),
		connections = {},
	}
	states[player] = state

	table.insert(
		state.connections,
		player:GetAttributeChangedSignal(Attr.Rank):Connect(function()
			local rank = numberAttr(player, Attr.Rank)
			-- The first write after join only reports the saved rank; only real rank-ups count.
			if state.rank > 0 and rank > state.rank then
				takeToken(state)
				sendProgression(player, "Rank", math.floor(rank))
			end
			state.rank = rank
		end)
	)
	table.insert(
		state.connections,
		player:GetAttributeChangedSignal(Attr.Rebirths):Connect(function()
			local rebirths = numberAttr(player, Attr.Rebirths)
			if rebirths > state.rebirths then
				takeToken(state)
				sendProgression(player, "Rebirth", math.floor(rebirths))
				TelemetryService.funnel(player, "FirstRebirth")
			end
			state.rebirths = rebirths
		end)
	)
	table.insert(
		state.connections,
		player:GetAttributeChangedSignal(Attr.TutorialDone):Connect(function()
			if player:GetAttribute(Attr.TutorialDone) == true then
				TelemetryService.funnel(player, "TutorialDone")
			end
		end)
	)

	TelemetryService.funnel(player, "Spawn")
	if state.rebirths >= 1 then
		TelemetryService.funnel(player, "FirstRebirth") -- no-op unless an older save missed it
	end
end

local function onProfileReleasing(player: Player)
	local state = states[player]
	if state == nil then
		return
	end
	states[player] = nil
	for _, connection in state.connections do
		connection:Disconnect()
	end
	flushEconomy(player, state, true)
	send("LogCustomEvent", player, "SessionLength", math.floor(math.max(0, os.clock() - state.joinClock)))
end

function TelemetryService:Init() end

function TelemetryService:Start()
	DataService.ProfileLoaded:Connect(onProfileLoaded)
	DataService.ProfileReleasing:Connect(onProfileReleasing)
	Players.PlayerRemoving:Connect(function(player: Player)
		-- Safety net: ProfileReleasing normally comes first and already cleaned up.
		local state = states[player]
		if state then
			states[player] = nil
			for _, connection in state.connections do
				connection:Disconnect()
			end
		end
	end)
	for _, player in Players:GetPlayers() do
		if DataService.isLoaded(player) then
			task.spawn(onProfileLoaded, player)
		end
	end

	task.spawn(function()
		while true do
			task.wait(ECONOMY_FLUSH_SEC)
			for player, state in states do
				flushEconomy(player, state, false)
			end
		end
	end)
end

return TelemetryService
