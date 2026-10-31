--!strict
-- Developer product catalog for "Aura Up!" v1 (T-069). Owned by integration-programmer.
-- The ONLY place in the repo that holds developer product ids and Robux prices. Must match docs/architecture.md
-- section 4f. Prices: owner approval D-038 (gate 5). Grant kinds: Types.GrantKind (D-023). Pure data and pure
-- helpers: no Roblox API calls, so qa can unit-test it and the client can read labels from it.
--
-- TODO(owner): every productId below is a placeholder 0. The owner creates each developer product in Creator Hub
-- (name, price and description: docs/architecture.md "Owner: create developer products") and pastes the numeric
-- id here. A product id is not a secret. Until an id is filled in, `canSell` refuses to start that purchase and
-- `byProductId` never matches it, so nothing can be sold or granted by accident.
--
-- All 23 `Types.ProductKey` keys have an entry, so the type stays one list. D-038 leaves 8 of them out of today's
-- scope (Speed Sneakers, Neon Pup, Neon Icon Fit, Tip5..Tip1000): they have `onSale = false`, no price, and the
-- owner does not create them. Selling one again needs a new owner price approval (gate 5).

local Types = require(script.Parent.Types)

type ProductKey = Types.ProductKey
type GrantKind = Types.GrantKind

export type Entry = {
	key: ProductKey,
	productId: number, -- Creator Hub developer product id; 0 = not created yet (never sellable)
	grantKind: GrantKind,
	onSale: boolean, -- false = outside the approved scope (D-038); never prompted, never granted
	priceRobux: number, -- approved price (D-038); 0 when not on sale
	priceLabel: string, -- shown in the shop, e.g. "4 R$"
	repeatable: boolean, -- true = can be bought again; false = once-only (permanent or one-time)
	nextTierOnly: boolean, -- ladder: only tier == owned tier + 1 may be prompted (D-016 #8, GDD 8e)
	tier: number?, -- ladder only: 1..5
	multiplier: number?, -- ladder only: 2, 4, 8, 16, 32
	hypeSec: number?, -- Hype Snack seconds this product grants (HypeSnack, StarterPack)
	petId: Types.PetId?, -- FixedPet / StarterPack: the fixed pet granted
	eggId: Types.EggId?, -- RobuxEgg only
	count: number?, -- RobuxEgg only: hatches per purchase (1 or 3)
	restrictedPetId: Types.PetId?, -- RobuxEgg only: fixed pet for a restricted player's receipt (GDD 5)
	displayName: string, -- Creator Hub product name
	description: string, -- Creator Hub description (owner pastes it)
}

export type LadderGrant = {
	tier: number?, -- set when the receipt is for the next tier: the new `entitlements.paidTier`
	hypeSec: number, -- set (> 0) when it is not: Hype Snack seconds to add instead (D-019 #3)
}

export type RestrictedGrant = {
	petId: Types.PetId,
	count: number,
}

local ProductCatalog = {}

-- D-019 #3: a ladder receipt that is not for the next tier grants 10 min of Hype Snack per 2 R$ paid.
ProductCatalog.HYPE_FALLBACK_SEC_PER_ROBUX = 300
ProductCatalog.LADDER_TIERS = 5
ProductCatalog.PLACEHOLDER_ID = 0

-- Listing text: lawyer T-071 listing review (docs/legal.md, L-1..L-13, D-056). Exact strings; do not reword.
-- LADDER_NOTE and PITY_RULE are exported so the shop and Robux egg UI show the same words as the listing.
local LADDER_NOTE = "Permanent. Does not stack: the highest tier you own applies. Works together with pets, VIP and "
	.. "Hype Snack. Only your next tier can be bought. If this tier can't be applied to you, you get Hype Snack time "
	.. "instead (10 min per 2 R$ paid)."
local PITY_RULE = "Pity: if 9 hatches of this egg in a row give no Legendary or better, your next hatch is a "
	.. "guaranteed Legendary (90%) or Mythic (10%). Your pity count is saved."
local PACK_LINE = "Each of the 3 hatches uses the same odds, and pity can trigger inside the pack. "
ProductCatalog.LADDER_NOTE = LADDER_NOTE
ProductCatalog.PITY_RULE = PITY_RULE

local function entry(e: Entry): Entry
	return table.freeze(e)
end

local function ladder(key: ProductKey, tier: number, price: number): Entry
	local mult = 2 ^ tier
	return entry({
		key = key,
		productId = 0, -- TODO(owner): paste the Creator Hub id
		grantKind = "PaidTier",
		onSale = true,
		priceRobux = price,
		priceLabel = `{price} R$`,
		repeatable = false,
		nextTierOnly = true,
		tier = tier,
		multiplier = mult,
		displayName = `x{mult} Mog Points`,
		description = `x{mult} Mog Points from tapping, pods and auto taps. {LADDER_NOTE}`,
	})
end

local function robuxEgg(
	key: ProductKey,
	eggId: Types.EggId,
	count: number,
	price: number,
	petId: Types.PetId,
	eggName: string,
	petName: string
): Entry
	local what = if count == 1 then `1 {eggName} hatch` else `{count} {eggName} hatches`
	local fallback = if count == 1 then petName else `{count} {petName} pets`
	local packLine = if count == 1 then "" else PACK_LINE
	return entry({
		key = key,
		productId = 0, -- TODO(owner): paste the Creator Hub id
		grantKind = "RobuxEgg",
		onSale = true,
		priceRobux = price,
		priceLabel = `{price} R$`,
		repeatable = true,
		nextTierOnly = false,
		eggId = eggId,
		count = count,
		restrictedPetId = petId,
		displayName = if count == 1 then eggName else `{eggName} x{count}`,
		description = `{what}. Odds for every pet are shown in game before you buy. {packLine}{PITY_RULE} If random `
			.. `items are not available on your account, you get {fallback} instead (no random roll).`,
	})
end

local function notOnSale(key: ProductKey, kind: GrantKind, name: string): Entry
	return entry({
		key = key,
		productId = 0, -- not created: outside today's scope (D-038)
		grantKind = kind,
		onSale = false,
		priceRobux = 0,
		priceLabel = "Not on sale",
		repeatable = kind == "Boost" or kind == "FixedPet" or kind == "Donation",
		nextTierOnly = false,
		displayName = name,
		description = "",
	})
end

local entries: { [ProductKey]: Entry } = {
	-- Multiplier ladder (permanent, next tier only), D-038: 4 / 8 / 19 / 39 / 79
	MpX2 = ladder("MpX2", 1, 4),
	MpX4 = ladder("MpX4", 2, 8),
	MpX8 = ladder("MpX8", 3, 19),
	MpX16 = ladder("MpX16", 4, 39),
	MpX32 = ladder("MpX32", 5, 79),

	HypeSnack = entry({
		key = "HypeSnack",
		productId = 0, -- TODO(owner): paste the Creator Hub id
		grantKind = "Boost",
		onSale = true,
		priceRobux = 2,
		priceLabel = "2 R$",
		repeatable = true,
		nextTierOnly = false,
		hypeSec = 600,
		displayName = "Hype Snack",
		description = "x2 Mog Points for 10 minutes, on top of your tier, pets and VIP. Boost time runs only while "
			.. "you are in the game. Buy more to add time, up to 2 hours in total.",
	}),
	SpeedSneakers = notOnSale("SpeedSneakers", "Boost", "Speed Sneakers"),

	AutoClicker = entry({
		key = "AutoClicker",
		productId = 0, -- TODO(owner): paste the Creator Hub id
		grantKind = "Entitlement",
		onSale = true,
		priceRobux = 39,
		priceLabel = "39 R$",
		repeatable = false,
		nextTierOnly = false,
		displayName = "Auto Clicker",
		description = "Permanent. 6 automatic taps per second for Mog Points (free players get 3 per second from "
			.. "Rank 3). Your own taps plus auto taps are capped at 12 per second. Auto taps pause in duels and when "
			.. "Auto-Tap is off in Settings.",
	}),

	RingLightRetriever = entry({
		key = "RingLightRetriever",
		productId = 0, -- TODO(owner): paste the Creator Hub id
		grantKind = "FixedPet",
		onSale = true,
		priceRobux = 29,
		priceLabel = "29 R$",
		repeatable = true,
		nextTierOnly = false,
		petId = "RingLightRetriever",
		displayName = "Ring Light Retriever",
		description = "One Ring Light Retriever pet: +1.00 MP bonus while equipped. Not random. Each purchase gives "
			.. "one more copy.",
	}),
	NeonPup = notOnSale("NeonPup", "FixedPet", "Neon Pup"),

	GoldenGlowFit = entry({
		key = "GoldenGlowFit",
		productId = 0, -- TODO(owner): paste the Creator Hub id
		grantKind = "Entitlement",
		onSale = true,
		priceRobux = 249,
		priceLabel = "249 R$",
		repeatable = false,
		nextTierOnly = false,
		displayName = "Golden Glow Fit",
		description = "Permanent. Exclusive outfit and aura. Cosmetic only, no stats.",
	}),
	NeonIconFit = notOnSale("NeonIconFit", "Entitlement", "Neon Icon Fit"),

	Vip = entry({
		key = "Vip",
		productId = 0, -- TODO(owner): paste the Creator Hub id
		grantKind = "Entitlement",
		onSale = true,
		priceRobux = 99,
		priceLabel = "99 R$",
		repeatable = false,
		nextTierOnly = false,
		displayName = "VIP",
		description = "Permanent. x1.25 Mog Points, +1 pet slot, gold name tag, VIP Sparkle Aura and +10 min "
			.. "Hype Snack on each daily reward claim.",
	}),

	StarterPack = entry({
		key = "StarterPack",
		productId = 0, -- TODO(owner): paste the Creator Hub id
		grantKind = "StarterPack",
		onSale = true,
		priceRobux = 9,
		priceLabel = "9 R$",
		repeatable = false,
		nextTierOnly = false,
		hypeSec = 1800,
		petId = "SparklePup",
		displayName = "Starter Pack",
		description = "One time only. 30 min Hype Snack (x2 Mog Points, in-game time), Sparkle Pup pet (+0.30 MP "
			.. "bonus while equipped) and Rookie Shades cosmetic.",
	}),

	-- Robux eggs, policy-gated (4d); restricted receipts grant the fixed pet, 3 copies for a 3-pack (GDD 5)
	StarEgg1 = robuxEgg("StarEgg1", "StarEgg", 1, 25, "StarlightCorgi", "Star Egg", "Starlight Corgi"),
	StarEgg3 = robuxEgg("StarEgg3", "StarEgg", 3, 69, "StarlightCorgi", "Star Egg", "Starlight Corgi"),
	GalaxyEgg1 = robuxEgg("GalaxyEgg1", "GalaxyEgg", 1, 49, "NebulaFox", "Galaxy Egg", "Nebula Fox"),
	GalaxyEgg3 = robuxEgg("GalaxyEgg3", "GalaxyEgg", 3, 129, "NebulaFox", "Galaxy Egg", "Nebula Fox"),

	-- Donations: not in today's scope (D-038)
	Tip5 = notOnSale("Tip5", "Donation", "Tip 5"),
	Tip25 = notOnSale("Tip25", "Donation", "Tip 25"),
	Tip100 = notOnSale("Tip100", "Donation", "Tip 100"),
	Tip500 = notOnSale("Tip500", "Donation", "Tip 500"),
	Tip1000 = notOnSale("Tip1000", "Donation", "Tip 1000"),
}

-- Load-time checks: one entry per ProductKey, keys match, ladder complete, ids unique when filled in.
local ladderByTier: { [number]: ProductKey } = {}
local byId: { [number]: Entry } = {}
local onSaleKeys: { ProductKey } = {}
local count = 0
for key, e in entries do
	count += 1
	assert(e.key == key, `ProductCatalog: entry {key} has key {e.key}`)
end
assert(
	count == #Types.ProductKeys,
	`ProductCatalog: {count} entries, Types.ProductKeys has {#Types.ProductKeys}`
)
for _, key in Types.ProductKeys do
	local e = entries[key]
	assert(e ~= nil, `ProductCatalog: missing entry for {key}`)
	assert(e.onSale == (e.priceRobux > 0), `ProductCatalog: {key} onSale and price disagree`)
	if e.onSale then
		table.insert(onSaleKeys, key)
	end
	if e.tier then
		assert(e.grantKind == "PaidTier" and e.nextTierOnly, `ProductCatalog: {key} ladder flags`)
		ladderByTier[e.tier] = key
	end
	if e.grantKind == "RobuxEgg" then
		assert(e.eggId and e.count and e.restrictedPetId, `ProductCatalog: {key} egg fields`)
	end
	if e.productId ~= 0 then
		assert(e.onSale, `ProductCatalog: {key} is not on sale but has a product id`)
		assert(byId[e.productId] == nil, `ProductCatalog: duplicate product id {e.productId}`)
		byId[e.productId] = e
	end
end
for tier = 1, ProductCatalog.LADDER_TIERS do
	assert(ladderByTier[tier] ~= nil, `ProductCatalog: ladder tier {tier} missing`)
end

-- Every entry, keyed by ProductKey (23, frozen). Read-only.
ProductCatalog.Entries = table.freeze(entries)
-- Keys with `onSale = true`, in Types.ProductKeys order (15). Shop UI lists these.
ProductCatalog.OnSaleKeys = table.freeze(onSaleKeys)

-- Entry for a key, or nil for anything that is not a ProductKey (safe on raw client strings).
function ProductCatalog.get(key: string): Entry?
	return (entries :: { [string]: Entry })[key]
end

-- Entry for a receipt's ProductId, or nil (unknown id, or the 0 placeholder). ProcessReceipt uses this.
function ProductCatalog.byProductId(productId: number): Entry?
	if productId == 0 then
		return nil
	end
	return byId[productId]
end

-- Ladder key for tier 1..5, or nil.
function ProductCatalog.ladderKey(tier: number): ProductKey?
	return ladderByTier[tier]
end

-- Whether the server may start a purchase prompt for this key at all (catalog-level check only;
-- MonetizationService still runs every RequestPurchase gate in section 2 #13). Refuses id 0 and not-on-sale keys.
function ProductCatalog.canSell(key: string): (boolean, string?)
	local e = ProductCatalog.get(key)
	if e == nil then
		return false, "UnknownKey"
	end
	if not e.onSale then
		return false, "NotOnSale"
	end
	if e.productId == 0 then
		return false, "NoProductId"
	end
	return true, nil
end

-- D-019 #3. What a ladder receipt grants, given the player's owned tier (0..5). Only a receipt for exactly the next
-- tier raises the tier; a receipt for an owned or lower tier (or a skip-ahead tier) grants Hype Snack time,
-- 10 min per 2 R$ of the catalog price, never the next tier. The Hype cap is bypassed for this grant (GDD 8e).
function ProductCatalog.ladderGrant(key: ProductKey, ownedTier: number): LadderGrant
	local e = entries[key]
	assert(e ~= nil and e.tier ~= nil, `ProductCatalog.ladderGrant: {key} is not a ladder product`)
	if e.tier == ownedTier + 1 then
		return { tier = e.tier, hypeSec = 0 }
	end
	return { tier = nil, hypeSec = e.priceRobux * ProductCatalog.HYPE_FALLBACK_SEC_PER_ROBUX }
end

-- GDD 5 / D-019 #4. The fixed pet and count a restricted player gets for a Robux egg receipt (no roll, pity unchanged).
function ProductCatalog.restrictedGrant(key: ProductKey): RestrictedGrant
	local e = entries[key]
	assert(e ~= nil and e.grantKind == "RobuxEgg", `ProductCatalog.restrictedGrant: {key} is not a Robux egg`)
	return { petId = e.restrictedPetId :: Types.PetId, count = e.count :: number }
end

-- Problems to log once at server start (MonetizationService.Start): on-sale products still on the 0 placeholder.
-- Empty list = every approved product has an id. Never errors, so Studio runs before the ids exist.
function ProductCatalog.missingIds(): { ProductKey }
	local missing = {}
	for _, key in onSaleKeys do
		if entries[key].productId == 0 then
			table.insert(missing, key)
		end
	end
	return missing
end

return table.freeze(ProductCatalog)
