--!strict
-- The one balance file for "Aura Up!" v1. Owned by gameplay-programmer.
-- Every number from GDD rev 2 sections 4-7 lives here (docs/gdd.md). Server and client read the same file, so
-- what the UI shows is what the server uses. Pure data and pure functions only: no Roblox services, no state.
-- qa checks these tables against the GDD (T-024). Change numbers here only; never hard-code them elsewhere.
-- Prices of Robux products are NOT here (Contracts/ProductCatalog, owner gate 5). Eggs and pets: T-027 (W1 eggs,
-- Star and Galaxy, fixed pets); Neon and Runway eggs and their pets come in T-090 (Update 1, D-035).

export type Tool = {
	name: string,
	mpPerTap: number,
	cost: number, -- coins, 0 = free
	world: number,
}

export type Pod = {
	name: string,
	mpPerSec: number, -- base MP/s before M
	cost: number, -- coins only (GDD 4.3 rev 1, no Robux path)
	world: number,
}

export type Boss = {
	id: string, -- builder sets this as the `BossId` attribute on the `BossStage` part (architecture 1f)
	name: string,
	world: number,
	mpNeed: number, -- threshold, never spent
	coins: number, -- coins per win before coinRebirthMult and Coin Snack
}

export type Rank = {
	name: string,
	lifetimeMp: number, -- lifetime MP needed to reach this rank
	lookId: string, -- model name in ServerStorage.Assets.Looks (builder, T-040/T-041)
}

export type EggPet = { petId: string, weight: number }
export type Egg = {
	name: string,
	world: number,
	currency: "Coins" | "Robux",
	price: number, -- coins per hatch (coin eggs); 0 on Robux eggs (Robux prices live in ProductCatalog)
	pets: { EggPet }, -- integer weights summing to ODDS_TOTAL, listed most common first
	restrictedGrant: string?, -- Robux eggs: the disclosed fixed pet for restricted players (D-016 #4)
	pityAt: number?, -- Robux eggs only: every Nth hatch with no Legendary+ is forced (GDD 5); nil = no pity
}
export type Pet = {
	name: string,
	rarity: string, -- one of RARITIES (Types.Rarity)
	bonus: number, -- added to the pet sum inside PetMult (GDD 4.1)
	fixed: boolean?, -- true = never rolled from an egg (Robux product or Starter Pack grant)
}

local EconomyConfig = {}

-- Caps and ranges (GDD 4, 5, 6; architecture 1c) --------------------------------------------------------
EconomyConfig.TAP_CAP_PER_SEC = 12 -- manual + auto taps accepted per second, PvE
EconomyConfig.TAP_BATCH_MAX = 30 -- largest count one TapBatch may carry
EconomyConfig.TAP_BURST_SEC = 1 -- tap bucket holds this many seconds of taps
EconomyConfig.DUEL_TAP_CAP_PER_SEC = 10
EconomyConfig.M_CLAMP = 10000 -- v1 server clamp on M (raised per world in later updates)
EconomyConfig.PET_MULT_CAP = 25
EconomyConfig.INVENTORY_CAP = 60
EconomyConfig.INVENTORY_HARD_CAP = 66 -- paid receipts may exceed INVENTORY_CAP by up to 6 (architecture 4b)
EconomyConfig.INTERACT_RANGE = 20 -- studs, boss stage and egg stand
EconomyConfig.ODDS_TOTAL = 10000 -- egg weights sum to this (0.5% = 50)
-- Option A (D-021, D-023): coin eggs open to everyone. Kept as a documented constant (architecture 1c);
-- no code reads it since T-029 removed the gate, so setting it to true changes nothing.
EconomyConfig.COIN_EGGS_POLICY_GATED = false

-- Boss fights (GDD 4, 4.4) -------------------------------------------------------------------------------
EconomyConfig.BOSS_FIGHT_SEC = 3 -- pose-off, then the award
EconomyConfig.BOSS_COOLDOWN_SEC = 1 -- rest after the award; cycle = 4 s
EconomyConfig.BOSS_CYCLE_SEC = EconomyConfig.BOSS_FIGHT_SEC + EconomyConfig.BOSS_COOLDOWN_SEC

-- Multiplier terms (GDD 4.1) -----------------------------------------------------------------------------
EconomyConfig.REBIRTH_MP_STEP = 0.5 -- RebirthMult = 1 + 0.5 x R
EconomyConfig.REBIRTH_COIN_STEP = 0.1 -- coin multiplier = 1 + 0.1 x R
EconomyConfig.PAID_TIER_MULTS = table.freeze({ 1, 2, 4, 8, 16, 32 }) -- index = tier + 1 (tier 0..5)
EconomyConfig.PAID_TIER_MAX = 5
EconomyConfig.VIP_MP_MULT = 1.25
EconomyConfig.HYPE_MP_MULT = 2 -- Hype Snack
EconomyConfig.COIN_SNACK_MULT = 2 -- free-only Coin Snack (daily D5, codes, events)
EconomyConfig.SPEED_WALK_MULT = 1.5 -- Speed Sneakers +50% walk speed
EconomyConfig.BOOST_CAP_SEC = 2 * 60 * 60 -- timed boosts stack to 2 h, in-game time only (GDD 8h)
EconomyConfig.HYPE_SNACK_SEC = 10 * 60 -- per Hype Snack purchase
EconomyConfig.SPEED_SNEAKERS_SEC = 30 * 60 -- per Speed Sneakers purchase

-- Rebirth and worlds (GDD 4.5) ---------------------------------------------------------------------------
EconomyConfig.REBIRTH_BASE_COST = 15000
EconomyConfig.REBIRTH_COST_GROWTH = 3
EconomyConfig.WORLD2_REBIRTHS = 3 -- portal unlocks at Rebirth 3

-- Auto systems (GDD 4.6) ---------------------------------------------------------------------------------
EconomyConfig.AUTO_TAP_FREE_RANK = 3
EconomyConfig.AUTO_TAP_FREE_RATE = 3 -- taps/s
EconomyConfig.AUTO_CLICKER_RATE = 6 -- taps/s (paid Auto Clicker)
EconomyConfig.AUTO_MOG_REBIRTHS = 1
EconomyConfig.AUTO_MOG_INTERVAL_SEC = 5

-- Pet slots (GDD 5) --------------------------------------------------------------------------------------
EconomyConfig.PET_SLOTS_BASE = 3
EconomyConfig.PET_SLOT_REBIRTHS = table.freeze({ 3, 8 }) -- +1 slot at each
EconomyConfig.PET_SLOTS_VIP = 1

-- Hatching (GDD 5, architecture 2 #6 and 4b) -------------------------------------------------------------
EconomyConfig.HATCH_MULTI_COUNT = 3 -- "hatch x3"
EconomyConfig.HATCH_MULTI_REBIRTHS = 2 -- hatch x3 unlocks at Rebirth 2 (free)
EconomyConfig.HATCH_LOCK_SEC = 1 -- server-side Hatching activity; the 2 s animation is client-only
EconomyConfig.AUTO_DELETE_RARITY = "Common" -- the "auto-delete Commons" setting removes this rarity only
EconomyConfig.PITY_LEGENDARY_WEIGHT = 9000 -- forced pity roll: Legendary 90% ...
EconomyConfig.PITY_MYTHIC_WEIGHT = 1000 -- ... Mythic 10% (sums to ODDS_TOTAL)
EconomyConfig.RARITIES = table.freeze({ "Common", "Uncommon", "Rare", "Epic", "Legendary", "Mythic" })

-- Duels (GDD 6) ------------------------------------------------------------------------------------------
EconomyConfig.DUEL_RANK_STEP = 0.03 -- Score = taps x (1 + 0.03 x RankEff)
EconomyConfig.DUEL_RANK_EDGE = 2 -- RankEff = min(own rank, opponent rank + 2)
EconomyConfig.DUEL_ACTIVE_SEC = 8
EconomyConfig.DUEL_COUNTDOWN_SEC = 3
EconomyConfig.DUEL_PENDING_SEC = 10
EconomyConfig.DUEL_RESULT_SEC = 2.5
EconomyConfig.DUEL_REMATCH_SEC = 10
EconomyConfig.DUEL_GRACE_SEC = 0.5
EconomyConfig.DUEL_REWARD_BOSS_SEC = 120 -- winner gets 2 min of their own best-boss coins/s
EconomyConfig.DUEL_REWARDS_PER_HOUR = 5
EconomyConfig.DUEL_REWARDS_PER_OPPONENT = 2 -- per 15 min
EconomyConfig.DUEL_OPPONENT_WINDOW_SEC = 15 * 60
EconomyConfig.DUEL_REWARD_WINDOW_SEC = 60 * 60 -- DUEL_REWARDS_PER_HOUR counts wins in this window
EconomyConfig.DUEL_TAP_TOTAL_MAX = EconomyConfig.DUEL_TAP_CAP_PER_SEC * EconomyConfig.DUEL_ACTIVE_SEC -- 80
EconomyConfig.DUEL_TAP_BURST_SEC = 1 -- unused duel tap allowance carried at most this long (lag, batching)
EconomyConfig.DUEL_CHALLENGE_COOLDOWN_SEC = 15 -- per target (GDD 6 anti-grief)
EconomyConfig.DUEL_DECLINE_MUTE_COUNT = 3 -- declines in a row from one target ...
EconomyConfig.DUEL_MUTE_SEC = 10 * 60 -- ... mute the challenger for that target this long
EconomyConfig.DUEL_BLOCK_MAX = 50 -- session block list size (architecture 2 #12)

-- Daily reward calendar (GDD 10, free only). Day = index 1..7 of the current streak; missing a UTC day restarts
-- at Day 1. `coinSec` = seconds of the player's own best-boss coins/s (BossService.bestCoinsPerSec). No paid item
-- changes these rows; VIP adds only DAILY_VIP_HYPE_SEC of Hype Snack per claim (GDD 8, 10).
export type DailyReward = {
	coinSec: number?, -- coins = floor(coinSec x best-boss coins/s)
	hypeSec: number?, -- free Hype Snack seconds (2 h cap applies)
	coinSnackSec: number?, -- free-only Coin Snack seconds (2 h cap applies)
	freeHatch: boolean?, -- one free coin-egg hatch of the best unlocked world (Basic in v1)
	cosmetic: string?, -- kept forever (entitlements.cosmetics)
}
local daily: { DailyReward } = {
	{ coinSec = 2 * 60 }, -- D1
	{ hypeSec = 10 * 60 }, -- D2
	{ coinSec = 5 * 60 }, -- D3
	{ freeHatch = true }, -- D4
	{ coinSnackSec = 15 * 60 }, -- D5
	{ coinSec = 10 * 60 }, -- D6
	{ cosmetic = "WeekStreakAura", coinSec = 15 * 60 }, -- D7
}
for _, row in daily do
	table.freeze(row)
end
EconomyConfig.DAILY_REWARDS = table.freeze(daily)
EconomyConfig.DAILY_VIP_HYPE_SEC = 10 * 60
EconomyConfig.DAY_SEC = 24 * 60 * 60 -- UTC day length for the calendar

-- Tools (GDD 4.2; reset on rebirth) ----------------------------------------------------------------------
local tools: { Tool } = {
	{ name = "Pocket Comb", mpPerTap = 1, cost = 0, world = 1 },
	{ name = "Hair Gel", mpPerTap = 2, cost = 50, world = 1 },
	{ name = "Bubble Face Mask", mpPerTap = 4, cost = 400, world = 1 },
	{ name = "Cool Shades", mpPerTap = 8, cost = 2000, world = 1 },
	{ name = "Fresh Kicks", mpPerTap = 15, cost = 7500, world = 1 },
	{ name = "Foam Dumbbell", mpPerTap = 30, cost = 25000, world = 1 },
	{ name = "Golden Mic", mpPerTap = 60, cost = 80000, world = 1 },
	{ name = "Aura Crystal", mpPerTap = 120, cost = 250000, world = 1 },
	{ name = "Neon Headphones", mpPerTap = 250, cost = 1000000, world = 2 },
	{ name = "Runway Jacket", mpPerTap = 500, cost = 4000000, world = 2 },
	{ name = "Star Shades", mpPerTap = 1000, cost = 15000000, world = 2 },
	{ name = "Crown of Drip", mpPerTap = 2000, cost = 60000000, world = 2 },
}

-- Glow Pods (GDD 4.3 rev 1; permanent, coins only) -------------------------------------------------------
local pods: { Pod } = {
	{ name = "Ring Light Pod", mpPerSec = 10, cost = 250, world = 1 },
	{ name = "Selfie Booth", mpPerSec = 40, cost = 3000, world = 1 },
	{ name = "Spa Steamer", mpPerSec = 150, cost = 15000, world = 1 },
	{ name = "Disco Mirror", mpPerSec = 500, cost = 60000, world = 1 },
	{ name = "Halo Lamp", mpPerSec = 1500, cost = 200000, world = 1 },
	{ name = "Neon Tube Pod", mpPerSec = 5000, cost = 1500000, world = 2 },
	{ name = "Spotlight Stage", mpPerSec = 15000, cost = 10000000, world = 2 },
}

-- Bosses (GDD 4.4; MP is a threshold, repeatable). Ordered weakest to strongest within each world. ---------
local bosses: { Boss } = {
	{ id = "SleepySid", name = "Sleepy Sid", world = 1, mpNeed = 100, coins = 10 },
	{ id = "BedheadBenny", name = "Bedhead Benny", world = 1, mpNeed = 600, coins = 30 },
	{ id = "SweatbandSal", name = "Sweatband Sal", world = 1, mpNeed = 3000, coins = 90 },
	{ id = "CaptainCardio", name = "Captain Cardio", world = 1, mpNeed = 12000, coins = 250 },
	{ id = "DukeOfDrip", name = "Duke of Drip", world = 1, mpNeed = 40000, coins = 600 },
	{ id = "GlowQueen", name = "Glow Queen", world = 1, mpNeed = 120000, coins = 1500 },
	{ id = "AuraTitan", name = "Aura Titan", world = 1, mpNeed = 400000, coins = 4000 },
	{ id = "LaserLarry", name = "Laser Larry", world = 2, mpNeed = 500000, coins = 10000 },
	{ id = "DjDazzle", name = "DJ Dazzle", world = 2, mpNeed = 1500000, coins = 30000 },
	{ id = "ChromeChamp", name = "Chrome Champ", world = 2, mpNeed = 5000000, coins = 80000 },
	{ id = "RunwayRex", name = "Runway Rex", world = 2, mpNeed = 15000000, coins = 200000 },
	{ id = "DivaSupreme", name = "Diva Supreme", world = 2, mpNeed = 50000000, coins = 500000 },
	{ id = "KingShine", name = "King Shine", world = 2, mpNeed = 150000000, coins = 1200000 },
}

-- Rank ladder (GDD 7; lifetime MP, never resets) ---------------------------------------------------------
local ranks: { Rank } = {
	{ name = "Fresh Spawn", lifetimeMp = 0, lookId = "FreshSpawn" },
	{ name = "Comb Rookie", lifetimeMp = 1800, lookId = "CombRookie" }, -- GDD rev 2 (D-033, QA-10): was 2,500
	{ name = "Glow Starter", lifetimeMp = 15000, lookId = "GlowStarter" },
	{ name = "Drip Apprentice", lifetimeMp = 60000, lookId = "DripApprentice" },
	{ name = "Style Scout", lifetimeMp = 250000, lookId = "StyleScout" },
	{ name = "Main Character", lifetimeMp = 1000000, lookId = "MainCharacter" },
	{ name = "Trendsetter", lifetimeMp = 5000000, lookId = "Trendsetter" },
	{ name = "Aura Farmer", lifetimeMp = 25000000, lookId = "AuraFarmer" },
	{ name = "Icon", lifetimeMp = 100000000, lookId = "Icon" },
	{ name = "Spotlight Legend", lifetimeMp = 500000000, lookId = "SpotlightLegend" },
	{ name = "Star Mogger", lifetimeMp = 2000000000, lookId = "StarMogger" },
	{ name = "Supreme Mogger", lifetimeMp = 10000000000, lookId = "SupremeMogger" },
}

-- Pets (GDD 5 table and GDD 8 fixed pets). Key = PetId (also the model name in ReplicatedStorage.Assets.Pets).
-- W2 coin-egg pets (Neon, Runway eggs) are added in T-090.
local pets: { [string]: Pet } = {
	-- Basic Egg (W1, coins)
	PuffPup = { name = "Puff Pup", rarity = "Common", bonus = 0.05 },
	BubbleBunny = { name = "Bubble Bunny", rarity = "Common", bonus = 0.08 },
	GlamHamster = { name = "Glam Hamster", rarity = "Uncommon", bonus = 0.15 },
	ShadesGecko = { name = "Shades Gecko", rarity = "Rare", bonus = 0.30 },
	MirrorFox = { name = "Mirror Fox", rarity = "Epic", bonus = 0.60 },
	-- Shiny Egg (W1, coins)
	SpaPanda = { name = "Spa Panda", rarity = "Common", bonus = 0.20 },
	GelPenguin = { name = "Gel Penguin", rarity = "Uncommon", bonus = 0.35 },
	DiscoDuck = { name = "Disco Duck", rarity = "Rare", bonus = 0.60 },
	SparkleOwl = { name = "Sparkle Owl", rarity = "Epic", bonus = 1.20 },
	GoldenGlowCat = { name = "Golden Glow Cat", rarity = "Legendary", bonus = 3.00 },
	-- Star Egg (W1, Robux; rolled in T-073)
	StarlightCorgi = { name = "Starlight Corgi", rarity = "Rare", bonus = 1.00 },
	AuraLion = { name = "Aura Lion", rarity = "Epic", bonus = 1.80 },
	HaloDragon = { name = "Halo Dragon", rarity = "Legendary", bonus = 3.50 },
	CosmicUnicorn = { name = "Cosmic Unicorn", rarity = "Mythic", bonus = 8.00 },
	-- Galaxy Egg (W1 since D-057, Robux; rolled in T-073)
	NebulaFox = { name = "Nebula Fox", rarity = "Rare", bonus = 3.00 },
	CometWolf = { name = "Comet Wolf", rarity = "Epic", bonus = 5.00 },
	SupernovaDragon = { name = "Supernova Dragon", rarity = "Legendary", bonus = 9.00 },
	GalaxyKraken = { name = "Galaxy Kraken", rarity = "Mythic", bonus = 20.00 },
	-- Fixed pets (GDD 8; never rolled). Rarity is a display label only (the GDD gives none).
	RingLightRetriever = { name = "Ring Light Retriever", rarity = "Rare", bonus = 1.00, fixed = true },
	NeonPup = { name = "Neon Pup", rarity = "Rare", bonus = 3.00, fixed = true },
	SparklePup = { name = "Sparkle Pup", rarity = "Rare", bonus = 0.30, fixed = true }, -- Starter Pack
}

-- Eggs (GDD 5). Weights are out of ODDS_TOTAL (10,000): 50% = 5000, 0.5% = 50. The egg UI renders these exact
-- rows and PetService rolls them, so the odds shown are the odds used.
local eggs: { [string]: Egg } = {
	BasicEgg = {
		name = "Basic Egg",
		world = 1,
		currency = "Coins",
		price = 500,
		pets = {
			{ petId = "PuffPup", weight = 5000 },
			{ petId = "BubbleBunny", weight = 3000 },
			{ petId = "GlamHamster", weight = 1500 },
			{ petId = "ShadesGecko", weight = 450 },
			{ petId = "MirrorFox", weight = 50 },
		},
	},
	ShinyEgg = {
		name = "Shiny Egg",
		world = 1,
		currency = "Coins",
		price = 10000,
		pets = {
			{ petId = "SpaPanda", weight = 4500 },
			{ petId = "GelPenguin", weight = 3500 },
			{ petId = "DiscoDuck", weight = 1500 },
			{ petId = "SparkleOwl", weight = 450 },
			{ petId = "GoldenGlowCat", weight = 50 },
		},
	},
	StarEgg = {
		name = "Star Egg",
		world = 1,
		currency = "Robux",
		price = 0,
		pets = {
			{ petId = "StarlightCorgi", weight = 6000 },
			{ petId = "AuraLion", weight = 3000 },
			{ petId = "HaloDragon", weight = 900 },
			{ petId = "CosmicUnicorn", weight = 100 },
		},
		restrictedGrant = "StarlightCorgi",
		pityAt = 10,
	},
	GalaxyEgg = {
		name = "Galaxy Egg",
		world = 1, -- GDD rev 3 5.2 (D-057): moved from World 2; odds, pity, prices and fallback unchanged
		currency = "Robux",
		price = 0,
		pets = {
			{ petId = "NebulaFox", weight = 6000 },
			{ petId = "CometWolf", weight = 3000 },
			{ petId = "SupernovaDragon", weight = 900 },
			{ petId = "GalaxyKraken", weight = 100 },
		},
		restrictedGrant = "NebulaFox",
		pityAt = 10,
	},
}

-- Display order for egg stands and UI lists (coin eggs first).
local eggIds: { string } = { "BasicEgg", "ShinyEgg", "StarEgg", "GalaxyEgg" }

local bossById: { [string]: Boss } = {}
for _, boss in bosses do
	bossById[boss.id] = table.freeze(boss)
end
for _, row in tools do
	table.freeze(row)
end
for _, row in pods do
	table.freeze(row)
end
for _, row in ranks do
	table.freeze(row)
end
for _, row in pets do
	table.freeze(row)
end
for _, egg in eggs do
	for _, entry in egg.pets do
		table.freeze(entry)
	end
	table.freeze(egg.pets)
	table.freeze(egg)
end

EconomyConfig.TOOLS = table.freeze(tools)
EconomyConfig.PODS = table.freeze(pods)
EconomyConfig.BOSSES = table.freeze(bosses)
EconomyConfig.BOSS_BY_ID = table.freeze(bossById)
EconomyConfig.RANKS = table.freeze(ranks)
EconomyConfig.EGGS = table.freeze(eggs)
EconomyConfig.PETS = table.freeze(pets)
EconomyConfig.EGG_IDS = table.freeze(eggIds)

-- Pure formula functions ---------------------------------------------------------------------------------

local function isFinite(x: number): boolean
	return x == x and x ~= math.huge and x ~= -math.huge
end

-- Clamps a count-like input (rebirths, tier, rank) to a non-negative integer; NaN/inf give 0.
local function count(x: number): number
	if not isFinite(x) or x < 0 then
		return 0
	end
	return math.floor(x)
end

-- Coins needed for rebirth number `n` (1 = the first rebirth): 15,000 x 3^(n-1).
function EconomyConfig.rebirthCost(n: number): number
	local k = math.max(1, count(n))
	return EconomyConfig.REBIRTH_BASE_COST * EconomyConfig.REBIRTH_COST_GROWTH ^ (k - 1)
end

-- MP multiplier from rebirths: 1 + 0.5 x R.
function EconomyConfig.rebirthMult(rebirths: number): number
	return 1 + EconomyConfig.REBIRTH_MP_STEP * count(rebirths)
end

-- Coin multiplier from rebirths: 1 + 0.1 x R.
function EconomyConfig.coinRebirthMult(rebirths: number): number
	return 1 + EconomyConfig.REBIRTH_COIN_STEP * count(rebirths)
end

-- Ladder multiplier for the highest owned tier (0..5): 1, 2, 4, 8, 16, 32. Tiers never stack.
function EconomyConfig.paidTierMult(tier: number): number
	local t = math.min(count(tier), EconomyConfig.PAID_TIER_MAX)
	return EconomyConfig.PAID_TIER_MULTS[t + 1]
end

-- Equip slots: 3, +1 at Rebirth 3, +1 at Rebirth 8, +1 with VIP.
function EconomyConfig.petSlots(rebirths: number, vip: boolean): number
	local r = count(rebirths)
	local slots = EconomyConfig.PET_SLOTS_BASE
	for _, need in EconomyConfig.PET_SLOT_REBIRTHS do
		if r >= need then
			slots += 1
		end
	end
	if vip then
		slots += EconomyConfig.PET_SLOTS_VIP
	end
	return slots
end

-- Duel score: taps x (1 + 0.03 x min(ownRank, oppRank + 2)). Pets, tiers, VIP and boosts never enter.
function EconomyConfig.duelScore(taps: number, ownRank: number, oppRank: number): number
	local rankEff = math.min(count(ownRank), count(oppRank) + EconomyConfig.DUEL_RANK_EDGE)
	return count(taps) * (1 + EconomyConfig.DUEL_RANK_STEP * rankEff)
end

-- Highest rank index (1..12) reached with `lifetimeMp`.
function EconomyConfig.rankForLifetimeMp(lifetimeMp: number): number
	local mp = if isFinite(lifetimeMp) then lifetimeMp else 0
	local rank = 1
	for i, row in EconomyConfig.RANKS do
		if mp >= row.lifetimeMp then
			rank = i
		else
			break
		end
	end
	return rank
end

-- Coins per second for farming `boss` at `rebirths` (no Coin Snack): coins x coinRebirthMult / cycle.
function EconomyConfig.bossCoinsPerSec(boss: Boss, rebirths: number): number
	return boss.coins * EconomyConfig.coinRebirthMult(rebirths) / EconomyConfig.BOSS_CYCLE_SEC
end

-- Pity odds (GDD 5): the forced hatch is Legendary PITY_LEGENDARY_WEIGHT / Mythic PITY_MYTHIC_WEIGHT out of
-- ODDS_TOTAL, from the egg's own Legendary and Mythic pets (validate() asserts one of each on Robux eggs).
-- Same rows the UI shows at 9/10 and PetService rolls, so the shown true odds are the odds used. Pure, no roll.
function EconomyConfig.pityOdds(egg: Egg): { EggPet }
	local rows: { EggPet } = {}
	for _, entry in egg.pets do
		local rarity = EconomyConfig.PETS[entry.petId].rarity
		if rarity == "Legendary" then
			table.insert(rows, { petId = entry.petId, weight = EconomyConfig.PITY_LEGENDARY_WEIGHT })
		elseif rarity == "Mythic" then
			table.insert(rows, { petId = entry.petId, weight = EconomyConfig.PITY_MYTHIC_WEIGHT })
		end
	end
	return rows
end

-- True odds of the NEXT hatch of `egg` with saved counter `pity`: the pity rows when this hatch is the pity hatch
-- (pity >= pityAt - 1), else the base table. Coin eggs always return the base table.
function EconomyConfig.nextHatchOdds(egg: Egg, pity: number): { EggPet }
	if egg.pityAt and isFinite(pity) and pity >= egg.pityAt - 1 then
		return EconomyConfig.pityOdds(egg)
	end
	return egg.pets
end

-- True for the rarities that reset the pity counter (Legendary or better).
function EconomyConfig.isPityHit(rarity: string): boolean
	return rarity == "Legendary" or rarity == "Mythic"
end

-- Asserts the tables are well formed. Runs at server start (BossService) and in qa tests (T-024).
function EconomyConfig.validate()
	local function ascending(list: { any }, field: string, label: string)
		for i = 2, #list do
			assert(list[i][field] > list[i - 1][field], `EconomyConfig: {label} {i} {field} must increase`)
		end
	end
	assert(#EconomyConfig.TOOLS == 12, "EconomyConfig: expected 12 tools")
	assert(#EconomyConfig.PODS == 7, "EconomyConfig: expected 7 pods")
	assert(#EconomyConfig.BOSSES == 13, "EconomyConfig: expected 13 bosses")
	assert(#EconomyConfig.RANKS == 12, "EconomyConfig: expected 12 ranks")
	assert(EconomyConfig.TOOLS[1].cost == 0, "EconomyConfig: tool 1 must be free")
	assert(EconomyConfig.RANKS[1].lifetimeMp == 0, "EconomyConfig: rank 1 must need 0 MP")
	ascending(EconomyConfig.TOOLS, "mpPerTap", "tool")
	ascending(EconomyConfig.TOOLS, "cost", "tool")
	ascending(EconomyConfig.PODS, "cost", "pod")
	ascending(EconomyConfig.BOSSES, "mpNeed", "boss")
	ascending(EconomyConfig.RANKS, "lifetimeMp", "rank")
	local seen: { [string]: boolean } = {}
	for _, boss in EconomyConfig.BOSSES do
		assert(
			#boss.id <= 32 and not seen[boss.id],
			`EconomyConfig: boss id "{boss.id}" too long or duplicated`
		)
		assert(boss.world == 1 or boss.world == 2, `EconomyConfig: boss "{boss.id}" has a bad world`)
		seen[boss.id] = true
	end
	local rarities: { [string]: boolean } = {}
	for _, rarity in EconomyConfig.RARITIES do
		rarities[rarity] = true
	end
	for petId, pet in EconomyConfig.PETS do
		assert(#petId <= 32 and rarities[pet.rarity], `EconomyConfig: pet {petId} has a bad id or rarity`)
		assert(
			pet.bonus > 0 and pet.bonus < EconomyConfig.PET_MULT_CAP,
			`EconomyConfig: pet {petId} bad bonus`
		)
	end
	local listed = 0
	for _, eggId in EconomyConfig.EGG_IDS do
		assert(EconomyConfig.EGGS[eggId], `EconomyConfig: EGG_IDS lists unknown egg {eggId}`)
		listed += 1
	end
	for eggId, egg in EconomyConfig.EGGS do
		listed -= 1
		local sum = 0
		local inEgg: { [string]: boolean } = {}
		for _, entry in egg.pets do
			local pet = EconomyConfig.PETS[entry.petId]
			assert(pet, `EconomyConfig: egg {eggId} has unknown pet {entry.petId}`)
			assert(not pet.fixed, `EconomyConfig: egg {eggId} rolls fixed pet {entry.petId}`)
			assert(not inEgg[entry.petId], `EconomyConfig: egg {eggId} lists {entry.petId} twice`)
			assert(
				entry.weight > 0 and entry.weight % 1 == 0,
				`EconomyConfig: egg {eggId} weight must be a whole number`
			)
			inEgg[entry.petId] = true
			sum += entry.weight
		end
		assert(sum == EconomyConfig.ODDS_TOTAL, `EconomyConfig: egg {eggId} weights sum to {sum}, not 10000`)
		if egg.currency == "Coins" then
			assert(
				egg.price > 0 and egg.price % 1 == 0,
				`EconomyConfig: coin egg {eggId} needs a whole price`
			)
			assert(egg.pityAt == nil, `EconomyConfig: coin egg {eggId} must not have pity (GDD 5)`)
			assert(egg.restrictedGrant == nil, `EconomyConfig: coin egg {eggId} has a restrictedGrant`)
		else
			assert(egg.price == 0, `EconomyConfig: Robux egg {eggId} price belongs in ProductCatalog`)
			local grant = egg.restrictedGrant
			assert(
				grant and inEgg[grant],
				`EconomyConfig: Robux egg {eggId} needs a restrictedGrant in its table`
			)
			assert(egg.pityAt and egg.pityAt >= 2, `EconomyConfig: Robux egg {eggId} needs pityAt`)
			local legendary, mythic = 0, 0
			for _, entry in egg.pets do
				local rarity = EconomyConfig.PETS[entry.petId].rarity
				legendary += if rarity == "Legendary" then 1 else 0
				mythic += if rarity == "Mythic" then 1 else 0
			end
			assert(
				legendary == 1 and mythic == 1,
				`EconomyConfig: Robux egg {eggId} needs one Legendary and one Mythic for pity`
			)
		end
	end
	assert(listed == 0, "EconomyConfig: EGG_IDS must list every egg exactly once")
	assert(
		EconomyConfig.PITY_LEGENDARY_WEIGHT + EconomyConfig.PITY_MYTHIC_WEIGHT == EconomyConfig.ODDS_TOTAL,
		"EconomyConfig: pity weights must sum to 10000"
	)
end

return table.freeze(EconomyConfig)
