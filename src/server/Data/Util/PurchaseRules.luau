--!strict
-- PurchaseRules: the pure rules behind MonetizationService (T-056). Owned by systems-programmer.
-- No Roblox services, no yields and no player state, so qa can unit-test every rule with plain tables.
-- Contract: docs/architecture.md section 2 #13 (RequestPurchase gates), 3c (ProcessReceipt), 4e (grant registry)
-- and 4f (ProductCatalog).
--
-- * `canPrompt` is the RequestPurchase gate (a UX gate, D-016 #9): it decides whether the server may OPEN a
--   purchase prompt. It never decides whether a paid receipt is delivered.
-- * `applyGrant` runs one receipt grant atomically: the registered grant fn works on a deep copy of the profile;
--   only if it returns true, does not error or yield, and leaves every coin-firewall field (GDD 8g) unchanged, the
--   copy is merged back into the live profile in place, together with the PurchaseId. Otherwise the live profile
--   is untouched, so a failed grant can be retried safely (no half grant, no recorded id without its grant).
--   The grant fn may return a second value, an `OnCommitted` hook (CR-I8, D-071). applyGrant passes it back only
--   when the grant was merged; MonetizationService runs it once, after the save holding the PurchaseId is confirmed.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ProductCatalog = require(ReplicatedStorage.Shared.Contracts.ProductCatalog)
local ProfileSchema = require(script.Parent.ProfileSchema)
local Types = require(ReplicatedStorage.Shared.Contracts.Types)

type ProfileData = Types.ProfileData
type Entry = ProductCatalog.Entry

-- CR-I8 (D-071): run once after the save that holds the PurchaseId is confirmed. May read the live profile; never
-- writes it. Everything the player sees about a grant (toasts, HatchResult, effects) goes here.
export type OnCommitted = (player: Player) -> ()
-- Returning `true` alone (no hook) stays valid; `false` discards any hook.
export type GrantFn = (player: Player, key: Types.ProductKey, data: ProfileData) -> (boolean, OnCommitted?)

export type PromptContext = {
	firstWin: boolean, -- BossService FirstWin (GDD 8a)
	paidRandomAllowed: boolean, -- ComplianceService, fail closed (4d)
	inventoryCap: number, -- EconomyConfig.INVENTORY_CAP (60)
	boostCapSec: number, -- EconomyConfig.BOOST_CAP_SEC (2 h)
	-- Live Hype Snack seconds left: MultiplierService.getBoostSec(player, "Hype"), read by MonetizationService at
	-- call time (architecture 1a, CR-G4). nil = MultiplierService not reachable: falls back to data.boosts.hypeSec.
	hypeSecLeft: number?,
}

local PurchaseRules = {}

PurchaseRules.KEY_MAX_LEN = 24

-- GDD 8g / architecture 4e: no grant may change these. Checked after every grant (defence in depth; qa's
-- firewall test is the main check).
PurchaseRules.FIREWALL_FIELDS =
	table.freeze({ "coins", "toolIndex", "podsMask", "rebirths", "world2Unlocked" })

local function finiteOr(value: any, default: number): number
	if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then
		return default
	end
	return value
end

-- Pets the profile holds (the inventory is a map keyed by uid).
function PurchaseRules.petCount(data: ProfileData): number
	local count = 0
	for _ in data.pets.inventory do
		count += 1
	end
	return count
end

function PurchaseRules.freeSlots(data: ProfileData, inventoryCap: number): number
	return math.max(0, inventoryCap - PurchaseRules.petCount(data))
end

-- True if the player already owns this permanent or once-only product (ladder tier or lower, Auto Clicker,
-- VIP, an exclusive fit, the Starter Pack). Repeatable products are never "owned".
function PurchaseRules.owns(data: ProfileData, key: string): boolean
	local entry = ProductCatalog.get(key)
	if entry == nil then
		return false
	end
	local ent = data.entitlements
	if entry.grantKind == "PaidTier" then
		return finiteOr(ent.paidTier, 0) >= (entry.tier or math.huge)
	elseif key == "AutoClicker" then
		return ent.autoClicker == true
	elseif key == "Vip" then
		return ent.vip == true
	elseif key == "StarterPack" then
		return ent.starterPack == true
	elseif key == "GoldenGlowFit" or key == "NeonIconFit" then
		return ent.cosmetics[key] == true
	end
	return false
end

-- RequestPurchase gate (architecture 2 #13) after the type/length/rate checks. Returns ok, reason.
-- Reasons: UnknownKey | NotOnSale | NoProductId (ProductCatalog.canSell) | FirstWin | NotNextTier | Owned |
-- Restricted | InventoryFull | BoostCap.
function PurchaseRules.canPrompt(data: ProfileData, key: string, ctx: PromptContext): (boolean, string?)
	local sellable, why = ProductCatalog.canSell(key)
	if not sellable then
		return false, why
	end
	local entry = ProductCatalog.get(key) :: Entry
	if not ctx.firstWin then
		return false, "FirstWin" -- GDD 8a: no prompt before the first boss win (receipts are still delivered)
	end
	if entry.nextTierOnly then
		if entry.tier ~= finiteOr(data.entitlements.paidTier, 0) + 1 then
			return false, "NotNextTier" -- D-016 #8: only the next ladder tier is ever prompted
		end
	end
	if not entry.repeatable and PurchaseRules.owns(data, key) then
		return false, "Owned"
	end
	if entry.grantKind == "RobuxEgg" then
		if not ctx.paidRandomAllowed then
			return false, "Restricted" -- 4d: Robux eggs are never prompted to restricted players
		end
		if PurchaseRules.freeSlots(data, ctx.inventoryCap) < (entry.count or 1) then
			return false, "InventoryFull"
		end
	elseif entry.grantKind == "FixedPet" or entry.grantKind == "StarterPack" then
		if PurchaseRules.freeSlots(data, ctx.inventoryCap) < 1 then
			return false, "InventoryFull"
		end
	end
	if entry.grantKind == "Boost" and entry.hypeSec then
		-- GDD 8h: refuse when the 2 h cap would be passed, so no paid time is wasted. Uses the live seconds left
		-- (CR-G4): `data.boosts.hypeSec` lags while Hype runs.
		local hypeSec = finiteOr(ctx.hypeSecLeft, finiteOr(data.boosts.hypeSec, 0))
		if hypeSec + entry.hypeSec > ctx.boostCapSec then
			return false, "BoostCap"
		end
	end
	return true, nil
end

-- Writes `src` into `dst` in place, keeping existing table identities (other services may hold sub-tables).
function PurchaseRules.mergeInPlace(dst: { [any]: any }, src: { [any]: any })
	for key in dst do
		if src[key] == nil then
			dst[key] = nil
		end
	end
	for key, value in src do
		local current = dst[key]
		if type(value) == "table" and type(current) == "table" then
			PurchaseRules.mergeInPlace(current, value)
		else
			dst[key] = value
		end
	end
end

-- The firewall field that a grant changed, or nil.
function PurchaseRules.firewallBreach(before: ProfileData, after: ProfileData): string?
	for _, field in PurchaseRules.FIREWALL_FIELDS do
		if (before :: any)[field] ~= (after :: any)[field] then
			return field
		end
	end
	return nil
end

-- ProcessReceipt step 4 (architecture 3c), run inside ONE DataService.update mutator. Returns ok, reason, hook.
-- ok = the grant and the PurchaseId are both in `data` now. Not ok = `data` is exactly as before and hook is nil.
-- hook = the grant fn's OnCommitted (CR-I8), only when ok; nil if the fn returned none (one-value grants stay valid).
-- Reasons: Duplicate (id already recorded: nothing changes, caller confirms the save) | GrantError | GrantRefused
-- | Firewall:<field>.
function PurchaseRules.applyGrant(
	data: ProfileData,
	player: Player,
	entry: Entry,
	purchaseId: string,
	grant: GrantFn
): (boolean, string?, OnCommitted?)
	if ProfileSchema.hasReceipt(data, purchaseId) then
		return false, "Duplicate", nil
	end
	local copy = ProfileSchema.deepCopy(data)
	local called, granted, onCommitted = pcall(grant, player, entry.key, copy)
	if not called then
		return false, "GrantError", nil
	end
	if granted ~= true then
		return false, "GrantRefused", nil
	end
	local breach = PurchaseRules.firewallBreach(data, copy)
	if breach then
		return false, `Firewall:{breach}`, nil
	end
	ProfileSchema.addReceipt(copy, purchaseId)
	PurchaseRules.mergeInPlace(data :: any, copy :: any)
	local hook: OnCommitted? = if type(onCommitted) == "function" then onCommitted else nil
	return true, nil, hook
end

-- True if a saved snapshot (DataService.saveAndConfirm predicate) holds `purchaseId`.
function PurchaseRules.savedHasReceipt(saved: { [any]: any }, purchaseId: string): boolean
	local receipts = saved.receipts
	return type(receipts) == "table" and table.find(receipts, purchaseId) ~= nil
end

-- Entitlement grant kind (registered by MonetizationService itself, 4e). Permanent flags only; a receipt for a
-- flag the player already has is still delivered (true) and changes nothing.
function PurchaseRules.entitlementGrant(
	_player: Player,
	key: Types.ProductKey,
	data: ProfileData
): (boolean, OnCommitted?)
	local ent = data.entitlements
	if key == "AutoClicker" then
		ent.autoClicker = true
	elseif key == "Vip" then
		ent.vip = true
		ent.cosmetics.VipSparkleAura = true
	elseif key == "GoldenGlowFit" or key == "NeonIconFit" then
		ent.cosmetics[key] = true
	else
		return false, nil -- not an Entitlement product
	end
	return true, nil
end

-- Donation grant kind (no tip is on sale in v1, D-038; kept so the registry is complete). Adds the catalog price
-- to the donor stat only: banner and name-tag colour, nothing else (GDD 8i).
function PurchaseRules.donationGrant(
	_player: Player,
	key: Types.ProductKey,
	data: ProfileData
): (boolean, OnCommitted?)
	local entry = ProductCatalog.get(key)
	if entry == nil or entry.grantKind ~= "Donation" or entry.priceRobux <= 0 then
		return false, nil
	end
	data.stats.robuxDonated = finiteOr(data.stats.robuxDonated, 0) + entry.priceRobux
	return true, nil
end

return table.freeze(PurchaseRules)
