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
}

export type ZoneApi = {
	getWorld: (player: Player) -> Types.WorldId,
	isNearBoss: (player: Player, bossId: string) -> boolean,
}

export type CharacterApi = {
	setLook: ((player: Player, lookId: string) -> ())?, -- arrives in sprint 2 (T-038)
	setSpeedMultiplier: ((player: Player, mult: number) -> ())?,
}

export type MonetizationApi = {
	EntitlementsChanged: RBXScriptSignal?,
	getPaidTier: ((player: Player) -> number)?,
	hasVip: ((player: Player) -> boolean)?,
}

export type TelemetryApi = {
	funnel: ((player: Player, step: Types.FunnelStep) -> ())?,
	economy: ((player: Player, flow: "Source" | "Sink", amount: number, reason: Types.CoinReason) -> ())?,
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

return Deps
