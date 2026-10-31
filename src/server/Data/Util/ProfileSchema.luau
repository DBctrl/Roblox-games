--!strict
-- Profile schema v1 (docs/architecture.md section 3a): defaults, reconcile, migrations, receipt-id dedupe.
-- Owned by systems-programmer. Pure functions only (no Roblox services), so qa can unit-test them.
--
-- Rules:
--   * `template()` returns a fresh deep copy of the v1 defaults every call.
--   * `reconcile(data)` fills missing fields from the template in place; it never overwrites a value that exists.
--   * `migrate(data)` upgrades older saves step by step to SCHEMA_VERSION in place. It returns false (and the
--     caller must NOT save) if the save comes from a newer schema than this server knows (a newer server wrote it):
--     loading and re-saving it here could drop fields, so DataService kicks with "please rejoin" instead.
--     It also returns false for a corrupt version (not an integer >= 1). DataService runs migrate + reconcile on
--     a copy inside pcall and only copies the result back on success, so a failure never changes the save.
--   * receipts: last RECEIPT_LIMIT PurchaseIds, oldest first (FIFO). Used by MonetizationService (T-056) so a
--     duplicate ProcessReceipt is never granted twice.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Types = require(ReplicatedStorage.Shared.Contracts.Types)

type ProfileData = Types.ProfileData

local ProfileSchema = {}

ProfileSchema.SCHEMA_VERSION = Types.PROFILE_SCHEMA_VERSION -- 1
ProfileSchema.RECEIPT_LIMIT = 100

-- SettingKey -> field in data.settings (one place, used by DataService and SetSetting validation).
ProfileSchema.SETTING_FIELDS = table.freeze({
	DuelRequests = "duelRequests",
	ShowOwnLook = "showOwnLook",
	AutoDeleteCommons = "autoDeleteCommons",
	HideFromDonorBoard = "hideFromDonorBoard",
	AutoTap = "autoTap",
	AutoMog = "autoMog",
} :: { [Types.SettingKey]: string })

-- SettingKey -> Player attribute name (Types.PlayerAttr, written by DataService only).
ProfileSchema.SETTING_ATTRS = table.freeze({
	DuelRequests = Types.PlayerAttr.SettingDuelRequests,
	ShowOwnLook = Types.PlayerAttr.SettingShowOwnLook,
	AutoDeleteCommons = Types.PlayerAttr.SettingAutoDeleteCommons,
	HideFromDonorBoard = Types.PlayerAttr.SettingHideFromDonorBoard,
	AutoTap = Types.PlayerAttr.SettingAutoTap,
	AutoMog = Types.PlayerAttr.SettingAutoMog,
} :: { [Types.SettingKey]: string })

function ProfileSchema.template(): ProfileData
	return {
		schemaVersion = ProfileSchema.SCHEMA_VERSION,
		coins = 0,
		mp = 0,
		lifetimeMp = 0,
		rebirths = 0,
		toolIndex = 1,
		podsMask = 0,
		world2Unlocked = false,
		firstWin = false,
		rank = 1,
		quest = { step = 1, done = false },
		pets = { inventory = {}, equipped = {}, nextUid = 1 },
		pity = {},
		entitlements = {
			paidTier = 0,
			vip = false,
			autoClicker = false,
			starterPack = false,
			cosmetics = {},
		},
		boosts = { hypeSec = 0, coinSec = 0, speedSec = 0 },
		daily = { streak = 0, lastClaimDay = 0 },
		codes = {},
		duel = { weekId = 0, weekWins = 0, rewardLog = {} },
		settings = {
			duelRequests = true,
			showOwnLook = true,
			autoDeleteCommons = false,
			hideFromDonorBoard = false,
			autoTap = true,
			autoMog = true,
		},
		stats = {
			firstJoinUnix = 0, -- set to os.time() by DataService on the first load
			playTimeSec = 0,
			totalCoinsEarned = 0,
			bossWins = 0,
			duelWins = 0,
			duelsPlayed = 0,
			robuxDonated = 0,
		},
		milestones = {},
		receipts = {},
	}
end

-- Fills every key that is missing in `target` from `defaults`, recursing into tables that exist on both sides.
-- A key whose saved value has the wrong type is left alone (never overwritten), except that a non-table value
-- where the template has a table is replaced, because no code could read it anyway.
local function fill(target: { [any]: any }, defaults: { [any]: any })
	for key, default in defaults do
		local current = target[key]
		if current == nil then
			target[key] = default -- template() is a fresh copy, so sharing is safe
		elseif type(default) == "table" then
			if type(current) == "table" then
				fill(current, default)
			else
				target[key] = default
			end
		end
	end
end

-- Adds missing fields with their defaults, in place. Safe to call on every load.
function ProfileSchema.reconcile(data: { [any]: any })
	fill(data, ProfileSchema.template() :: any)
end

-- Migration steps: MIGRATIONS[n] upgrades a save from version n to n + 1, in place. None yet (v1 is the first
-- shipped schema, D-023). Add a step here, bump Types.PROFILE_SCHEMA_VERSION (Contract request), never edit a
-- shipped step.
local MIGRATIONS: { [number]: (data: { [any]: any }) -> () } = {}

-- Returns true if `data` is now at SCHEMA_VERSION, false if it is from a newer schema (do not load or save it).
-- Returns (true) on success, or (false, "newer" | "corrupt"). A version that is present but not an integer >= 1
-- (0, -1, 0.5, inf) is corrupt: nothing is changed and the caller must not save over it (QA-11).
function ProfileSchema.migrate(data: { [any]: any }): (boolean, string?)
	local version = data.schemaVersion
	if version == nil then
		version = 1 -- pre-versioned save: treat as v1, reconcile fills the rest
	end
	if type(version) ~= "number" or version ~= version or version % 1 ~= 0 or version < 1 then
		return false, "corrupt"
	end
	if version > ProfileSchema.SCHEMA_VERSION then
		return false, "newer"
	end
	while version < ProfileSchema.SCHEMA_VERSION do
		local step = MIGRATIONS[version]
		assert(step, `ProfileSchema: missing migration step {version} -> {version + 1}`)
		step(data)
		version += 1
	end
	data.schemaVersion = ProfileSchema.SCHEMA_VERSION
	return true
end

-- Receipt-id dedupe -----------------------------------------------------------------------------------

function ProfileSchema.hasReceipt(data: ProfileData, purchaseId: string): boolean
	return table.find(data.receipts, purchaseId) ~= nil
end

-- Appends `purchaseId` (if new) and trims the list to RECEIPT_LIMIT, dropping the oldest first.
function ProfileSchema.addReceipt(data: ProfileData, purchaseId: string)
	if table.find(data.receipts, purchaseId) then
		return
	end
	table.insert(data.receipts, purchaseId)
	while #data.receipts > ProfileSchema.RECEIPT_LIMIT do
		table.remove(data.receipts, 1)
	end
end

-- Deep copy for snapshots (saved-data checks, tests). Plain data only: no cycles, no Instances.
function ProfileSchema.deepCopy<V>(value: V): V
	if type(value) ~= "table" then
		return value
	end
	local out = {}
	for k, v in value :: any do
		out[k] = ProfileSchema.deepCopy(v)
	end
	return out :: any
end

return table.freeze(ProfileSchema)
