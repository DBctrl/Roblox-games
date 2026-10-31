--!strict
-- The one balance file for "Aura Up!" v1. Owned by gameplay-programmer.
-- Every number from GDD rev 1 sections 4-7 lives here (docs/gdd.md). Server and client read the same file, so
-- what the UI shows is what the server uses. Pure data and pure functions only: no Roblox services, no state.
-- qa checks these tables against the GDD (T-024). Change numbers here only; never hard-code them elsewhere.
-- Prices of Robux products are NOT here (Contracts/ProductCatalog, owner gate 5). Eggs and pets: T-027 (sprint 2).

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
	price: number, -- coins per hatch (coin eggs); Robux prices live in ProductCatalog
	pets: { EggPet }, -- integer weights summing to ODDS_TOTAL
	restrictedGrant: string?, -- Robux eggs: the disclosed fixed pet for restricted players (D-016 #4)
}
export type Pet = { name: string, rarity: string, bonus: number }

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
EconomyConfig.COIN_EGGS_POLICY_GATED = false -- option A (D-021, D-023): coin eggs open to everyone

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
	{ name = "Comb Rookie", lifetimeMp = 2500, lookId = "CombRookie" },
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

-- Eggs and pets: filled by T-027 (sprint 2). Empty maps keep the architecture 1c surface stable.
local eggs: { [string]: Egg } = {}
local pets: { [string]: Pet } = {}

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

EconomyConfig.TOOLS = table.freeze(tools)
EconomyConfig.PODS = table.freeze(pods)
EconomyConfig.BOSSES = table.freeze(bosses)
EconomyConfig.BOSS_BY_ID = table.freeze(bossById)
EconomyConfig.RANKS = table.freeze(ranks)
EconomyConfig.EGGS = table.freeze(eggs)
EconomyConfig.PETS = table.freeze(pets)

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
	for eggId, egg in EconomyConfig.EGGS do
		local sum = 0
		for _, entry in egg.pets do
			assert(
				EconomyConfig.PETS[entry.petId],
				`EconomyConfig: egg {eggId} has unknown pet {entry.petId}`
			)
			assert(
				entry.weight > 0 and entry.weight % 1 == 0,
				`EconomyConfig: egg {eggId} weight must be a whole number`
			)
			sum += entry.weight
		end
		assert(sum == EconomyConfig.ODDS_TOTAL, `EconomyConfig: egg {eggId} weights sum to {sum}, not 10000`)
	end
end

return table.freeze(EconomyConfig)
