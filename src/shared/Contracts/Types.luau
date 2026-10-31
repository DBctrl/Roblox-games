--!strict
-- Shared cross-module types and name constants for "Aura Up!" v1. Owned by integration-programmer.
-- Must match docs/architecture.md. Change only through a "Contract request" in docs/architecture.md section 8.
-- Types only plus frozen name tables: no logic, no Roblox API calls.
-- Balance numbers (costs, odds, caps) are NOT here: they live in src/shared/Gameplay/EconomyConfig.

-- Worlds, activity, progression ----------------------------------------------------------------------

export type WorldId = number -- 1 = Glow Town, 2 = Neon Runway

-- Exclusive per-player activity. Writer: Gameplay/ActivityService.
export type Activity = "Idle" | "BossFight" | "Hatching" | "Duel"

export type MpSource = "Tap" | "AutoTap" | "Pod"

export type CoinReason =
	"BossWin"
	| "DuelReward"
	| "Daily"
	| "Code"
	| "Pack"
	| "StarterPack"
	| "Tool"
	| "Pod"
	| "Egg"
	| "Rebirth"

export type BoostKind = "Hype" | "Coin" | "Speed"

export type SettingKey =
	"DuelRequests"
	| "ShowOwnLook"
	| "AutoDeleteCommons"
	| "HideFromDonorBoard"
	| "AutoTap"
	| "AutoMog"

-- Eggs and pets -------------------------------------------------------------------------------------

export type EggId = "BasicEgg" | "ShinyEgg" | "StarEgg" | "NeonEgg" | "RunwayEgg" | "GalaxyEgg"

export type Rarity = "Common" | "Uncommon" | "Rare" | "Epic" | "Legendary" | "Mythic"

export type PetId = string -- key in EconomyConfig.PETS
export type PetUid = string -- per-profile unique id ("1", "2", ...), max 12 chars

export type HatchedPet = {
	uid: PetUid?, -- nil when auto-deleted
	petId: PetId,
	rarity: Rarity,
	isNew: boolean, -- first time this player owns this pet id
	autoDeleted: boolean,
	pity: boolean, -- true if the pity rule forced this result
}

-- Monetization (34 developer products; ids and prices live in Contracts/ProductCatalog, sprint 1) ----

export type ProductKey =
	"MpX2"
	| "MpX4"
	| "MpX8"
	| "MpX16"
	| "MpX32"
	| "HypeSnack"
	| "CoinSnack"
	| "SpeedSneakers"
	| "CoinPouch"
	| "CoinBag"
	| "CoinVault"
	| "PodUnlock2"
	| "PodUnlock3"
	| "PodUnlock4"
	| "PodUnlock5"
	| "PodUnlock6"
	| "PodUnlock7"
	| "AutoClicker"
	| "AutoMogEarly"
	| "SkipRebirth"
	| "SkipWorld2"
	| "GoldenGlowFit"
	| "NeonIconFit"
	| "Vip"
	| "StarterPack"
	| "StarEgg1"
	| "StarEgg3"
	| "GalaxyEgg1"
	| "GalaxyEgg3"
	| "Tip5"
	| "Tip25"
	| "Tip100"
	| "Tip500"
	| "Tip1000"

-- Which service's registered grant function handles a product (MonetizationService.registerGrant).
export type GrantKind =
	"PaidTier" -- MonetizationService itself
	| "Entitlement" -- MonetizationService itself (Vip, AutoClicker, AutoMogEarly, fits)
	| "Boost" -- MultiplierService
	| "CoinPack" -- RewardService
	| "PodUnlock" -- ShopService
	| "SkipRebirth" -- RebirthService
	| "SkipWorld2" -- ZoneService
	| "StarterPack" -- RewardService
	| "RobuxEgg" -- PetService
	| "Donation" -- MonetizationService itself

-- Analytics -----------------------------------------------------------------------------------------

export type FunnelStep =
	"Spawn"
	| "FirstTap"
	| "FirstWin"
	| "FirstUpgrade"
	| "FirstPod"
	| "FirstRankUp"
	| "FirstEgg"
	| "TutorialDone"
	| "FirstRebirth"

export type CustomEvent = "Purchase" | "DuelPlayed" | "DuelWon" | "DuelDraw" | "DuelForfeit" | "SessionLength"

export type LeaderboardId = "LifetimeMp" | "Rebirths" | "DuelWinsWeek" | "Donors"

-- Profile data (schema v1, see docs/architecture.md section 3a) -------------------------------------

export type ProfileData = {
	schemaVersion: number, -- 1
	coins: number,
	mp: number,
	lifetimeMp: number,
	rebirths: number,
	skipRebirthsUsed: number,
	toolIndex: number, -- 1..12
	podsMask: number, -- bit i (1..7) = pod i owned
	world2Unlocked: boolean,
	firstWin: boolean,
	rank: number, -- 1..12
	quest: { step: number, done: boolean },
	pets: {
		inventory: { [PetUid]: { id: PetId } },
		equipped: { PetUid },
		nextUid: number,
	},
	pity: { [EggId]: number }, -- Robux eggs only
	entitlements: {
		paidTier: number, -- 0..5 (0 = none, 5 = x32)
		vip: boolean,
		autoClicker: boolean,
		autoMogEarly: boolean,
		starterPack: boolean,
		cosmetics: { [string]: boolean },
	},
	boosts: { hypeSec: number, coinSec: number, speedSec: number }, -- remaining seconds, online only
	daily: { streak: number, lastClaimDay: number }, -- lastClaimDay = UTC days since epoch, 0 = never
	codes: { [string]: boolean },
	duel: {
		weekId: number,
		weekWins: number,
		rewardLog: { { t: number, opp: number } }, -- rewarded wins in the last hour (unix time, opponent UserId)
	},
	settings: {
		duelRequests: boolean,
		showOwnLook: boolean,
		autoDeleteCommons: boolean,
		hideFromDonorBoard: boolean,
		autoTap: boolean,
		autoMog: boolean,
	},
	stats: {
		firstJoinUnix: number,
		playTimeSec: number,
		totalCoinsEarned: number,
		bossWins: number,
		duelWins: number,
		duelsPlayed: number,
		robuxDonated: number,
	},
	milestones: { [FunnelStep]: boolean },
	receipts: { string }, -- last 100 processed PurchaseIds (ProcessReceipt idempotency)
}

-- Remote payloads -----------------------------------------------------------------------------------

export type NotifyKind = "Info" | "Success" | "Error" | "Banner" | "Donation"

export type NotifyPayload = {
	kind: NotifyKind,
	text: string, -- built on the server, never echoes client strings
	durationSec: number?,
}

export type EffectId =
	"BossWin"
	| "RankUp"
	| "Rebirth"
	| "DuelKnockback"
	| "DuelBounce"
	| "Purchase"
	| "Donation"
	| "DailyReward"

export type EffectPayload = {
	userId: number?,
	bossId: string?,
	amount: number?,
	rank: number?,
	rebirths: number?,
	direction: Vector3?, -- DuelKnockback: unit vector to the ring's foam pit
	productKey: ProductKey?,
	tier: number?, -- Donation: 1..5
}

export type HatchResultPayload = {
	eggId: EggId,
	pets: { HatchedPet },
	pity: number?, -- new pity counter (Robux eggs only)
}

export type DuelPhase = "Invited" | "Waiting" | "Countdown" | "Active" | "Result" | "Rematch" | "Ended"

export type DuelResult = "Win" | "Lose" | "Draw" | "Forfeit"

export type DuelStatePayload = {
	phase: DuelPhase,
	opponentUserId: number?,
	startsAt: number?, -- workspace:GetServerTimeNow() time the phase's clock starts
	endsAt: number?, -- workspace:GetServerTimeNow() time the phase ends
	myScore: number?, -- Result only
	theirScore: number?, -- Result only
	result: DuelResult?, -- Result only
	rewardCoins: number?, -- Result only, 0 when capped
	reason: string?, -- Ended: "Declined" | "Timeout" | "Left" | "Cancelled"
}

-- Name constants (use these, never string literals, for attributes and tags) ------------------------

local Types = {}

Types.PROFILE_SCHEMA_VERSION = 1

-- Attributes on the Player instance. One writer each (see docs/architecture.md section 1e).
Types.PlayerAttr = table.freeze({
	-- DataService
	DataLoaded = "DataLoaded", -- boolean
	Coins = "Coins", -- number
	Mp = "Mp", -- number
	LifetimeMp = "LifetimeMp", -- number
	Rebirths = "Rebirths", -- number
	SettingDuelRequests = "SettingDuelRequests", -- boolean
	SettingShowOwnLook = "SettingShowOwnLook", -- boolean
	SettingAutoDeleteCommons = "SettingAutoDeleteCommons", -- boolean
	SettingHideFromDonorBoard = "SettingHideFromDonorBoard", -- boolean
	SettingAutoTap = "SettingAutoTap", -- boolean
	SettingAutoMog = "SettingAutoMog", -- boolean
	-- MonetizationService
	PaidTier = "PaidTier", -- number 0..5
	Vip = "Vip", -- boolean
	AutoClickerOwned = "AutoClickerOwned", -- boolean
	AutoMogEarlyOwned = "AutoMogEarlyOwned", -- boolean
	StarterPackOwned = "StarterPackOwned", -- boolean
	-- ComplianceService
	PaidRandomAllowed = "PaidRandomAllowed", -- boolean, false until checked (fail closed)
	-- ZoneService
	WorldId = "WorldId", -- number 1..2
	World2Unlocked = "World2Unlocked", -- boolean
	CurrentPod = "CurrentPod", -- number, 0 = none
	-- ActivityService
	Activity = "Activity", -- Activity
	-- MultiplierService
	Multiplier = "Multiplier", -- number, M after clamp (display only)
	CoinMultiplier = "CoinMultiplier", -- number
	HypeEndsAt = "HypeEndsAt", -- number, server time, 0 = off
	CoinSnackEndsAt = "CoinSnackEndsAt", -- number, server time, 0 = off
	SpeedEndsAt = "SpeedEndsAt", -- number, server time, 0 = off
	-- RankService
	Rank = "Rank", -- number 1..12
	LookId = "LookId", -- string
	-- ShopService
	ToolIndex = "ToolIndex", -- number 1..12
	PodsMask = "PodsMask", -- number, bit i = pod i owned
	-- PetService
	EquippedPets = "EquippedPets", -- string, comma-separated pet ids (for rendering)
	PetCount = "PetCount", -- number
	PetSlots = "PetSlots", -- number
	PityStarEgg = "PityStarEgg", -- number 0..9
	PityGalaxyEgg = "PityGalaxyEgg", -- number 0..9
	-- BossService
	FirstWin = "FirstWin", -- boolean
	BestCoinsPerSec = "BestCoinsPerSec", -- number
	-- TapService
	MpPerTap = "MpPerTap", -- number
	-- RebirthService
	RebirthCost = "RebirthCost", -- number
	-- IdleService
	IdleMpPerSec = "IdleMpPerSec", -- number
	AutoTapRate = "AutoTapRate", -- number taps/s, 0 = off
	AutoMogUnlocked = "AutoMogUnlocked", -- boolean
	-- DuelService
	InDuel = "InDuel", -- boolean
	DuelWinsWeek = "DuelWinsWeek", -- number
	-- QuestService
	QuestStep = "QuestStep", -- number
	TutorialDone = "TutorialDone", -- boolean
	-- RewardService
	DailyStreak = "DailyStreak", -- number 0..7
	DailyClaimable = "DailyClaimable", -- boolean
	DailyNextClaimUnix = "DailyNextClaimUnix", -- number
})

-- Attributes builder sets on tagged map parts (read-only for code; see architecture.md section 1f).
Types.MapAttr = table.freeze({
	WorldId = "WorldId", -- number
	BossId = "BossId", -- string
	PodIndex = "PodIndex", -- number 1..7
	EggId = "EggId", -- EggId
	Shop = "Shop", -- "Tools" | "Robux"
	RingIndex = "RingIndex", -- number 1..2
	ToWorldId = "ToWorldId", -- number
	Board = "Board", -- LeaderboardId
	Place = "Place", -- number 1..3 (podium)
})

-- CollectionService tags placed by builder in the Studio place.
Types.Tag = table.freeze({
	BossStage = "BossStage",
	Pod = "Pod",
	EggStand = "EggStand",
	ShopStand = "ShopStand",
	MogRing = "MogRing",
	Portal = "Portal",
	Spawn = "Spawn",
	Leaderboard = "Leaderboard",
	Podium = "Podium",
})

return table.freeze(Types)
