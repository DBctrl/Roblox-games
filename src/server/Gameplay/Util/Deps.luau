--!strict
-- Typed access to the Data and World services that Gameplay calls (architecture 1a: Gameplay -> World -> Data).
-- Owned by gameplay-programmer. Not a service (lives in Util/, so the bootstrap skips it).
--
-- Why lookups instead of top-level requires: some APIs arrive in later sprints (PetService S2, TelemetryService
-- S2, MonetizationService S3, CharacterService.setLook S2), and PetService sits above MultiplierService in the
-- layer order. Resolving at call time avoids require cycles and lets every caller nil-guard what is not there yet.
-- DataService is mandatory: `Deps.data()` errors if it is missing. Every other accessor returns nil when absent,
-- and callers fail closed (no award) or skip the cosmetic call.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Types = require(ReplicatedStorage.Shared.Contracts.Types)

type ProfileData = Types.ProfileData

export type DataApi = {
	ProfileLoaded: RBXScriptSignal,
	ProfileReleasing: RBXScriptSignal,
	isLoaded: (player: Player) -> boolean,
	getData: (player: Player) -> ProfileData?,
	addCoins: (player: Player, amount: number, reason: Types.CoinReason) -> number,
	trySpendCoins: (player: Player, amount: number, reason: Types.CoinReason) -> boolean,
	update: (player: Player, mutator: (data: ProfileData) -> ()) -> boolean,
	getSetting: (player: Player, key: Types.SettingKey) -> boolean,
}

export type ZoneApi = {
	getWorld: (player: Player) -> Types.WorldId,
	isNearBoss: (player: Player, bossId: string) -> boolean,
	isNearEggStand: ((player: Player, eggId: Types.EggId) -> boolean)?, -- arrives in sprint 2 (T-038)
	getPod: ((player: Player) -> number)?, -- arrives in sprint 2 (T-038); 0 = in no pod
	-- Mog rings (T-059, sprint 3). releaseRing must be called exactly once per reservation.
	reserveRing: ((worldId: Types.WorldId) -> number?)?,
	releaseRing: ((worldId: Types.WorldId, ringIndex: number) -> ())?,
	teleportToRing: ((player: Player, worldId: Types.WorldId, ringIndex: number, side: number) -> ())?,
	getRingKnockback: ((worldId: Types.WorldId, ringIndex: number) -> Vector3)?,
	isInRing: ((player: Player, worldId: Types.WorldId, ringIndex: number) -> boolean)?,
}

export type ComplianceApi = {
	paidRandomAllowed: ((player: Player) -> boolean)?,
}

export type DuelApi = {
	isInDuel: ((player: Player) -> boolean)?, -- DuelService arrives in sprint 3
}

export type CharacterApi = {
	setLook: ((player: Player, lookId: string) -> ())?, -- arrives in sprint 2 (T-038)
	setSpeedMultiplier: ((player: Player, mult: number) -> ())?,
	setMovementLocked: ((player: Player, reason: string, locked: boolean) -> ())?,
}

-- Grant fn contract (architecture 1b, 3c, 4e, section 8 CR-I8): mutates only `data`, synchronously, inside
-- MonetizationService's one DataService.update that also records the receipt id; returns false = cannot grant now
-- (NotProcessedYet; any hook is discarded). It never messages the client. Whatever the player should see goes in
-- the optional OnCommitted hook, which MonetizationService runs once after the save holding the receipt id is
-- confirmed. The hook may read the live profile and refresh attributes; it must not write the profile.
export type OnCommitted = (player: Player) -> ()
export type GrantFn = (player: Player, key: Types.ProductKey, data: ProfileData) -> (boolean, OnCommitted?)

export type MonetizationApi = {
	EntitlementsChanged: RBXScriptSignal?,
	registerGrant: ((kind: Types.GrantKind, fn: GrantFn) -> ())?, -- arrives in sprint 3 (T-056)
	getPaidTier: ((player: Player) -> number)?,
	hasVip: ((player: Player) -> boolean)?,
	owns: ((player: Player, key: Types.ProductKey) -> boolean)?,
}

export type TelemetryApi = {
	funnel: ((player: Player, step: Types.FunnelStep) -> ())?,
	economy: ((player: Player, flow: "Source" | "Sink", amount: number, reason: Types.CoinReason) -> ())?,
	custom: ((player: Player, name: Types.CustomEvent, value: number?) -> ())?,
}

export type PetApi = {
	getPetMultiplierSum: ((player: Player) -> number)?,
}

local serverRoot = script.Parent.Parent.Parent -- Util -> Gameplay -> Server
local cache: { [string]: any } = {}

local function find(folder: string, name: string): any?
	local key = `{folder}/{name}`
	local hit = cache[key]
	if hit ~= nil then
		return hit
	end
	local folderInst = serverRoot:FindFirstChild(folder)
	local moduleInst = folderInst and folderInst:FindFirstChild(name)
	if moduleInst and moduleInst:IsA("ModuleScript") then
		local mod = (require :: any)(moduleInst)
		cache[key] = mod
		return mod
	end
	return nil
end

local Deps = {}

function Deps.data(): DataApi
	local mod = find("Data", "DataService")
	assert(mod, "Gameplay needs Data/DataService (T-012)")
	return mod :: DataApi
end

function Deps.zone(): ZoneApi?
	return find("World", "ZoneService") :: ZoneApi?
end

function Deps.character(): CharacterApi?
	return find("World", "CharacterService") :: CharacterApi?
end

function Deps.monetization(): MonetizationApi?
	return find("Data", "MonetizationService") :: MonetizationApi?
end

function Deps.telemetry(): TelemetryApi?
	return find("Data", "TelemetryService") :: TelemetryApi?
end

function Deps.pets(): PetApi?
	return find("Gameplay", "PetService") :: PetApi?
end

function Deps.compliance(): ComplianceApi?
	return find("Data", "ComplianceService") :: ComplianceApi?
end

function Deps.duel(): DuelApi?
	return find("Gameplay", "DuelService") :: DuelApi?
end

-- True while the player is in a duel. DuelService is the source; the Activity check covers the gap before it lands.
function Deps.inDuel(player: Player, activity: Types.Activity): boolean
	if activity == "Duel" then
		return true
	end
	local duel = Deps.duel()
	local fn = duel and duel.isInDuel
	return fn ~= nil and fn(player) == true
end

-- Fire-and-forget telemetry: never errors, never yields the caller.
function Deps.funnel(player: Player, step: Types.FunnelStep)
	local telemetry = Deps.telemetry()
	local fn = telemetry and telemetry.funnel
	if fn then
		task.spawn(fn, player, step)
	end
end

function Deps.economy(player: Player, flow: "Source" | "Sink", amount: number, reason: Types.CoinReason)
	local telemetry = Deps.telemetry()
	local fn = telemetry and telemetry.economy
	if fn then
		task.spawn(fn, player, flow, amount, reason)
	end
end

function Deps.custom(player: Player, name: Types.CustomEvent, value: number?)
	local telemetry = Deps.telemetry()
	local fn = telemetry and telemetry.custom
	if fn then
		task.spawn(fn, player, name, value)
	end
end

-- Registers a receipt grant with MonetizationService (T-056). Returns false (and warns once per kind) when the
-- registry is not there yet, so a missing T-056 never errors a Start(). Call from Start() only.
function Deps.registerGrant(kind: Types.GrantKind, fn: GrantFn): boolean
	local monetization = Deps.monetization()
	local register = monetization and monetization.registerGrant
	if register == nil then
		warn(`[Gameplay] MonetizationService.registerGrant missing; {kind} receipts are not granted yet`)
		return false
	end
	register(kind, fn)
	return true
end

-- True when Robux eggs may roll for this player. Fails closed: no ComplianceService or no answer yet = false.
function Deps.paidRandomAllowed(player: Player): boolean
	local compliance = Deps.compliance()
	local fn = compliance and compliance.paidRandomAllowed
	return fn ~= nil and fn(player) == true
end

return Deps
