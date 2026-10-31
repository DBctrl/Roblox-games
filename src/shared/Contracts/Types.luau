--!strict
-- Shared cross-module types and name constants. Owned by integration-programmer.
-- Must match docs/architecture.md. Change only through a "Contract request" in docs/architecture.md.
-- Types only plus frozen name tables: no logic, no Roblox API calls.

-- Plots and progression ---------------------------------------------------------------------------

export type PlotId = number -- 1..6 (builder sets the PlotId attribute on each plot model)

export type UpgradeId = "FasterGears" | "SugarGlaze"

export type PadId =
	"Dropper1"
	| "Dropper2"
	| "Dropper3"
	| "Dropper4"
	| "Dropper5"
	| "Dropper6"
	| "Dropper7"
	| "Dropper8"
	| "Dropper9"
	| "Dropper10"
	| "FasterGears"
	| "SugarGlaze"

-- Hidden: not shown. Available: visible and buyable by the owner. Owned: bought (or upgrade at max level).
export type PadState = "Hidden" | "Available" | "Owned"

-- What World needs to draw a plot. Gameplay computes it from the profile; World applies it.
export type PlotProgress = {
	droppersOwned: number, -- 1..10, droppers are bought in fixed order, Gumdrop (1) is free
	gearsLevel: number, -- 0..3
	glazeLevel: number, -- 0..3
}

-- Profile data (schema v1, see docs/architecture.md section 3) ------------------------------------

export type ProfileData = {
	schemaVersion: number, -- 1
	cash: number,
	droppersOwned: number,
	upgrades: { FasterGears: number, SugarGlaze: number },
	rebirths: number,
	daily: {
		streak: number, -- 0..7, 0 = never claimed
		lastClaimUnix: number, -- 0 = never
	},
	stats: {
		totalCashEarned: number,
		robuxDonated: number,
		firstJoinUnix: number,
		playTimeSec: number,
	},
	settings: {
		hideFromDonorBoard: boolean,
	},
	badges: { [string]: boolean }, -- BadgeKey -> awarded
	receipts: { string }, -- last 50 processed PurchaseIds (ProcessReceipt idempotency)
}

export type CashReason = "Income" | "DailyReward" | "Purchase" | "Rebirth"

export type BadgeKey = "Welcome" | "FirstRebirth" | "Rebirth5" | "Rebirth10"

export type LeaderboardId = "Rebirths" | "TotalCash" | "Donors"

-- 0 = no multiplier pass, 1..4 = x2 / x4 / x8 / x16 (highest owned tier applies)
export type PassTier = number

-- Remote payloads ---------------------------------------------------------------------------------

export type NotifyKind = "Info" | "Success" | "Error" | "Donation"

export type NotifyPayload = {
	kind: NotifyKind,
	text: string,
	durationSec: number?,
}

export type EffectId = "PlotClaimed" | "Purchase" | "Rebirth" | "DailyReward" | "Donation"

export type EffectPayload = {
	plotId: PlotId?,
	padId: PadId?,
	amount: number?,
	userId: number?,
	tier: number?,
}

-- Name constants (use these, never string literals, for attributes and tags) -----------------------

local Types = {}

Types.PROFILE_SCHEMA_VERSION = 1

-- Attributes on the Player instance. One writer each (see docs/architecture.md section 1).
Types.PlayerAttr = table.freeze({
	DataLoaded = "DataLoaded", -- boolean, DataService
	Cash = "Cash", -- number, DataService
	Rebirths = "Rebirths", -- number, DataService
	HideFromDonorBoard = "HideFromDonorBoard", -- boolean, DataService
	PassTier = "PassTier", -- number 0..4, MonetizationService
	PlotId = "PlotId", -- number 0 = none, PlotService
	IncomePerSec = "IncomePerSec", -- number, IncomeService
	TotalMultiplier = "TotalMultiplier", -- number, IncomeService
	RebirthCost = "RebirthCost", -- number, RebirthService
	DailyStreak = "DailyStreak", -- number, DailyRewardService
	DailyClaimable = "DailyClaimable", -- boolean, DailyRewardService
	DailyNextClaimUnix = "DailyNextClaimUnix", -- number, DailyRewardService
})

-- Attributes on plot models and pads. Writer: PlotService only.
Types.PlotAttr = table.freeze({
	PlotId = "PlotId", -- number, set by builder in the place
	OwnerUserId = "OwnerUserId", -- number, 0 = free
	DroppersOwned = "DroppersOwned", -- number 0..10 (0 while unclaimed)
	GearsLevel = "GearsLevel", -- number 0..3
	GlazeLevel = "GlazeLevel", -- number 0..3
	PadState = "PadState", -- PadState, on each pad part
	PadLevel = "PadLevel", -- number, next level to buy on upgrade pads
})

-- CollectionService tags placed by builder in the Studio place.
Types.Tag = table.freeze({
	Plot = "Plot",
	Leaderboard = "Leaderboard", -- with attribute Board: LeaderboardId
})

return table.freeze(Types)
