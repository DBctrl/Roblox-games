--!strict
-- DataService: player profiles, the Data API, data attributes, leaderstats and the SetSetting handler.
-- Owned by systems-programmer. Contract: docs/architecture.md section 3 (schema v1, Data API) and 1e (attributes).
--
-- * Profiles are session-locked through Util/ProfileBackend (ProfileStore, or the UpdateAsync fallback until T-001
--   installs it). A failed load NEVER creates or saves defaults: the player is kicked with a friendly message.
-- * Saves: auto-save (backend), on leave and on shutdown (BindToClose here waits for every session to end).
-- * `update` is the only way any service changes profile data. Mutators run synchronously; a mutator that
--   yields or errors returns false (with a warning). Coins/MP/rebirth counters are guarded against NaN, infinity
--   and negatives after every mutator.
-- * Attributes (DataLoaded, Coins, Mp, LifetimeMp, Rebirths, Setting*) and leaderstats (Rank, Rebirths) are
--   flushed at most 5 Hz per player, and only when changed.
-- * Logs never contain names or other personal info.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ProfileBackend = require(script.Parent.Util.ProfileBackend)
local ProfileSchema = require(script.Parent.Util.ProfileSchema)
local RateLimit = require(ReplicatedStorage.Shared.Contracts.RateLimit)
local Types = require(ReplicatedStorage.Shared.Contracts.Types)

type ProfileData = Types.ProfileData
type Session = ProfileBackend.Session

local Attr = Types.PlayerAttr

local STORE_NAME = "AuraUp_PlayerData_v1"
local FLUSH_INTERVAL_SEC = 0.2 -- 5 Hz
local DEFAULT_WAIT_SEC = 30
local CLOSE_TIMEOUT_SEC = 25
local SETTING_KEY_MAX_LEN = 32
-- GDD 4.6: Auto-Tap unlocks at Rank 3 or with the Auto Clicker. TODO(CR-3): read an `AutoTapUnlocked` attribute
-- from IdleService instead of this copy of the rank.
local AUTO_TAP_UNLOCK_RANK = 3

local KICK_LOAD_FAILED =
	"We couldn't load your save right now. Your progress is safe. Please rejoin in a minute."
local KICK_NEWER_SAVE = "Aura Up! was just updated. Please rejoin to play the new version."
local KICK_SESSION_LOST = "Your save was opened on another server. Please rejoin."

type PlayerState = {
	session: Session,
	data: ProfileData,
	joinClock: number,
	dirty: boolean,
	releasing: boolean,
	written: { [string]: any }, -- last value written per attribute
	rankValue: IntValue,
	rebirthsValue: IntValue,
}

local DataService = {}

local backend: ProfileBackend.Backend? = nil
local states: { [Player]: PlayerState } = {}
local loading: { [Player]: boolean } = {}
local profileLoadedEvent: BindableEvent
local profileReleasingEvent: BindableEvent

local function isFiniteNonNegative(n: any): boolean
	return type(n) == "number" and n == n and n >= 0 and n ~= math.huge
end

-- The four counters every economy path touches. Restored if a mutator leaves them invalid.
local GUARDED_FIELDS = { "coins", "mp", "lifetimeMp", "rebirths" }

local function liveState(player: Player): PlayerState?
	local state = states[player]
	if state == nil or state.releasing then
		return nil
	end
	return state
end

-- Attributes ------------------------------------------------------------------------------------------

local function setAttr(player: Player, state: PlayerState, name: string, value: any)
	if state.written[name] ~= value then
		state.written[name] = value
		player:SetAttribute(name, value)
	end
end

local function settingValue(data: ProfileData, key: Types.SettingKey): boolean
	local field = ProfileSchema.SETTING_FIELDS[key]
	local value = (data.settings :: any)[field] == true
	if key == "DuelRequests" then
		value = value and data.quest.done == true -- duels stay off until the tutorial is done (GDD 6)
	end
	return value
end

local function flush(player: Player, state: PlayerState)
	state.dirty = false
	local data = state.data
	setAttr(player, state, Attr.Coins, data.coins)
	setAttr(player, state, Attr.Mp, data.mp)
	setAttr(player, state, Attr.LifetimeMp, data.lifetimeMp)
	setAttr(player, state, Attr.Rebirths, data.rebirths)
	for key, attrName in ProfileSchema.SETTING_ATTRS do
		setAttr(player, state, attrName, settingValue(data, key))
	end
	local rank = math.floor(tonumber(data.rank) or 1)
	if state.rankValue.Value ~= rank then
		state.rankValue.Value = rank
	end
	local rebirths = math.floor(data.rebirths)
	if state.rebirthsValue.Value ~= rebirths then
		state.rebirthsValue.Value = rebirths
	end
end

local function makeLeaderstats(player: Player): (IntValue, IntValue)
	local old = player:FindFirstChild("leaderstats")
	if old then
		old:Destroy()
	end
	local folder = Instance.new("Folder")
	folder.Name = "leaderstats"
	local rankValue = Instance.new("IntValue")
	rankValue.Name = "Rank"
	rankValue.Parent = folder
	local rebirthsValue = Instance.new("IntValue")
	rebirthsValue.Name = "Rebirths"
	rebirthsValue.Parent = folder
	folder.Parent = player
	return rankValue, rebirthsValue
end

-- Session lifecycle -----------------------------------------------------------------------------------

local function sanitize(data: ProfileData)
	for _, field in GUARDED_FIELDS do
		local value = (data :: any)[field]
		if not isFiniteNonNegative(value) then
			warn(`DataService: saved field {field} was invalid; reset to 0`);
			(data :: any)[field] = 0
		end
	end
	if data.stats.firstJoinUnix == 0 then
		data.stats.firstJoinUnix = os.time()
	end
end

local function release(player: Player)
	local state = states[player]
	if state == nil or state.releasing then
		return
	end
	state.releasing = true
	profileReleasingEvent:Fire(player)
	task.wait() -- let deferred ProfileReleasing handlers run before the final snapshot
	state.data.stats.playTimeSec += math.max(0, os.clock() - state.joinClock)
	states[player] = nil
	state.session.endSession()
end

local function load(player: Player)
	local currentBackend = backend
	if currentBackend == nil or states[player] or loading[player] then
		return
	end
	loading[player] = true
	local session, reason = currentBackend.startSession(`Player_{player.UserId}`, player.UserId, function()
		return player.Parent ~= Players
	end)
	loading[player] = nil

	if session == nil then
		if player.Parent == Players then
			warn(`DataService: profile load failed ({reason}); kicking with rejoin message`)
			player:Kick(KICK_LOAD_FAILED)
		end
		return
	end
	if player.Parent ~= Players then
		session.endSession()
		return
	end

	local data = session.data
	if not ProfileSchema.migrate(data) then
		warn("DataService: save is from a newer schema; not loading it")
		session.endSession()
		player:Kick(KICK_NEWER_SAVE)
		return
	end
	ProfileSchema.reconcile(data)
	sanitize(data :: any)

	local rankValue, rebirthsValue = makeLeaderstats(player)
	local state: PlayerState = {
		session = session,
		data = data :: any,
		joinClock = os.clock(),
		dirty = false,
		releasing = false,
		written = {},
		rankValue = rankValue,
		rebirthsValue = rebirthsValue,
	}
	states[player] = state

	session.onSessionEnd(function(endReason: string)
		-- Ended without us releasing it (lock taken by another server, or the store ended it): stop writing.
		if states[player] == state and not state.releasing then
			states[player] = nil
			warn(`DataService: session ended unexpectedly ({endReason})`)
			if player.Parent == Players then
				player:Kick(KICK_SESSION_LOST)
			end
		end
	end)

	flush(player, state)
	player:SetAttribute(Attr.DataLoaded, true)
	profileLoadedEvent:Fire(player, data)
end

local function onClose()
	for player in states do
		task.spawn(release, player)
	end
	local deadline = os.clock() + CLOSE_TIMEOUT_SEC
	while os.clock() < deadline do
		local current = backend
		if current == nil or current.activeCount() == 0 then
			break
		end
		task.wait(0.25)
	end
end

-- SetSetting ------------------------------------------------------------------------------------------

local function autoTapAvailable(player: Player): boolean
	if player:GetAttribute(Attr.AutoClickerOwned) == true then
		return true
	end
	local rank = player:GetAttribute(Attr.Rank)
	return type(rank) == "number" and rank >= AUTO_TAP_UNLOCK_RANK
end

local function onSetSetting(player: Player, key: any, value: any)
	if typeof(key) ~= "string" or #key > SETTING_KEY_MAX_LEN or typeof(value) ~= "boolean" then
		return
	end
	if player:GetAttribute(Attr.DataLoaded) ~= true then
		return
	end
	local field = (ProfileSchema.SETTING_FIELDS :: any)[key]
	if field == nil then
		return
	end
	local state = liveState(player)
	if state == nil or (state.data.settings :: any)[field] == value then
		return -- not loaded, or no-op
	end
	-- Turning a setting off is always allowed; turning an automation on needs it unlocked.
	if value == true then
		if key == "AutoTap" and not autoTapAvailable(player) then
			return
		end
		if key == "AutoMog" and player:GetAttribute(Attr.AutoMogUnlocked) ~= true then
			return
		end
	end
	DataService.update(player, function(data)
		(data.settings :: any)[field] = value
	end)
end

-- Public API (architecture section 3b) ----------------------------------------------------------------

DataService.ProfileLoaded = (nil :: any) :: RBXScriptSignal -- (player: Player, data: T.ProfileData)
DataService.ProfileReleasing = (nil :: any) :: RBXScriptSignal -- (player: Player) just before the session ends

function DataService.isLoaded(player: Player): boolean
	return liveState(player) ~= nil
end

-- READ-ONLY for callers: change data only through `update`. Still returns data during ProfileReleasing.
function DataService.getData(player: Player): ProfileData?
	local state = states[player]
	return if state then state.data else nil
end

-- Yields until the profile is loaded, the player leaves, or `timeoutSec` (default 30) passes.
function DataService.waitForData(player: Player, timeoutSec: number?): ProfileData?
	local deadline = os.clock() + (timeoutSec or DEFAULT_WAIT_SEC)
	while player.Parent == Players and os.clock() < deadline do
		local state = liveState(player)
		if state then
			return state.data
		end
		task.wait(0.1)
	end
	local state = liveState(player)
	return if state then state.data else nil
end

-- Runs `mutator(data)` synchronously. Returns false if the profile isn't loaded or the mutator errors or yields
-- (a yielding mutator is stopped). Changes made before an error stay applied, so keep mutators short.
-- Allowed during ProfileReleasing (so services can write final values) until the final snapshot is taken.
function DataService.update(player: Player, mutator: (data: ProfileData) -> ()): boolean
	local state = states[player]
	if state == nil then
		return false
	end
	local data = state.data
	local before = {}
	for _, field in GUARDED_FIELDS do
		before[field] = (data :: any)[field]
	end

	local thread = coroutine.create(mutator)
	local ok, err = coroutine.resume(thread, data)
	if coroutine.status(thread) ~= "dead" then
		coroutine.close(thread)
		ok, err = false, "mutator yielded"
	end
	if not ok then
		warn(`DataService.update: {err}`)
	end

	for _, field in GUARDED_FIELDS do
		if not isFiniteNonNegative((data :: any)[field]) then
			warn(`DataService.update: rejected invalid {field}`);
			(data :: any)[field] = before[field]
		end
	end
	state.dirty = true
	return ok
end

-- Adds coins (amount finite and > 0). Returns the new balance, or 0 if nothing was added.
function DataService.addCoins(player: Player, amount: number, _reason: Types.CoinReason): number
	if not (isFiniteNonNegative(amount) and amount > 0) then
		return 0
	end
	local balance = 0
	local ok = DataService.update(player, function(data)
		data.coins += amount
		data.stats.totalCoinsEarned += amount
		balance = data.coins
	end)
	-- TelemetryService.economy(player, "Source", amount, reason) is wired in T-033.
	return if ok then balance else 0
end

-- Spends coins if the player has enough. amount must be finite and >= 0 (0 always succeeds).
function DataService.trySpendCoins(player: Player, amount: number, _reason: Types.CoinReason): boolean
	if not isFiniteNonNegative(amount) then
		return false
	end
	local state = liveState(player)
	if state == nil or state.data.coins < amount then
		return false
	end
	if amount == 0 then
		return true
	end
	local spent = false
	DataService.update(player, function(data)
		if data.coins >= amount then
			data.coins -= amount
			spent = true
		end
	end)
	-- TelemetryService.economy(player, "Sink", amount, reason) is wired in T-033.
	return spent
end

function DataService.getSetting(player: Player, key: Types.SettingKey): boolean
	local state = liveState(player)
	if state == nil or ProfileSchema.SETTING_FIELDS[key] == nil then
		return false
	end
	return settingValue(state.data, key)
end

-- **Yields.** Saves now and waits until a save whose data passes `predicate` has been written (for example
-- "contains PurchaseId X" in ProcessReceipt, architecture 3c step 5). Returns false on timeout (default 30 s) or
-- if the session ends first. Systems-internal (MonetizationService); see Contract request CR-3 in my summary.
function DataService.saveAndConfirm(
	player: Player,
	predicate: (saved: { [any]: any }) -> boolean,
	timeoutSec: number?
): boolean
	local state = liveState(player)
	if state == nil then
		return false
	end
	local session = state.session
	local confirmed = false
	local disconnect = session.onAfterSave(function(saved)
		if not confirmed and type(saved) == "table" and predicate(saved) then
			confirmed = true
		end
	end)
	session.save()
	local deadline = os.clock() + (timeoutSec or DEFAULT_WAIT_SEC)
	local nextNudge = os.clock() + 6
	while not confirmed and session.isActive() and os.clock() < deadline do
		task.wait(0.1)
		if os.clock() >= nextNudge then
			nextNudge = os.clock() + 6
			session.save() -- the first save may have been throttled or raced with a mutation
		end
	end
	disconnect()
	return confirmed
end

-- Lifecycle -------------------------------------------------------------------------------------------

function DataService:Init()
	profileLoadedEvent = Instance.new("BindableEvent")
	profileReleasingEvent = Instance.new("BindableEvent")
	DataService.ProfileLoaded = profileLoadedEvent.Event
	DataService.ProfileReleasing = profileReleasingEvent.Event
end

function DataService:Start()
	RateLimit.connect("SetSetting", onSetSetting)
	Players.PlayerRemoving:Connect(release)
	game:BindToClose(onClose)

	task.spawn(function()
		while true do
			task.wait(FLUSH_INTERVAL_SEC)
			for player, state in states do
				if state.dirty and not state.releasing then
					flush(player, state)
				end
			end
		end
	end)

	backend = ProfileBackend.create(STORE_NAME, ProfileSchema.template :: any) -- yields (Studio probe)
	Players.PlayerAdded:Connect(load)
	for _, player in Players:GetPlayers() do
		task.spawn(load, player)
	end
end

return DataService
