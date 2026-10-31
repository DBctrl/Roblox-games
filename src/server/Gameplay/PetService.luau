--!strict
-- PetService (architecture 1b #12 and 4b, layer L1). Owned by gameplay-programmer.
-- Coin-egg hatching (`HatchEgg`), the pet inventory, equip/unequip (`EquipPet`) and multi-delete (`DeletePets`).
-- The client sends only an egg id + count, or pet uids; price, odds, roll, slots and ownership are server-side.
-- The roll uses one server `Random` and the weights in EconomyConfig.EGGS (the same table the egg UI shows).
-- Cost, roll and inventory insert happen in ONE DataService.update, so a hatch is all-or-nothing.
-- Every equip, unequip or delete ends with MultiplierService.refresh (CR-c, D-032), so M is never stale.
-- Sole writer of EquippedPets, PetCount, PetSlots, PityStarEgg and PityGalaxyEgg.
-- Lean v1 (D-034): coin eggs (Basic, Shiny) only. Robux eggs, pity rolls and receipt grants (FixedPet,
-- StarterPack, RobuxEgg) are built in T-073 / sprint 3; until then `grantEgg` refuses Robux eggs.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ActivityService = require(script.Parent.ActivityService)
local Deps = require(script.Parent.Util.Deps)
local EconomyConfig = require(ReplicatedStorage.Shared.Gameplay.EconomyConfig)
local Guard = require(script.Parent.Util.Guard)
local MultiplierService = require(script.Parent.MultiplierService)
local NumberFormat = require(ReplicatedStorage.Shared.Contracts.NumberFormat)
local PetRoll = require(script.Parent.Util.PetRoll)
local RateLimit = require(ReplicatedStorage.Shared.Contracts.RateLimit)
local Remotes = require(ReplicatedStorage.Shared.Contracts.Remotes)
local Types = require(ReplicatedStorage.Shared.Contracts.Types)

local Attr = Types.PlayerAttr

type ProfileData = Types.ProfileData
type Egg = EconomyConfig.Egg
type HatchedPet = Types.HatchedPet

local EGG_ID_MAX_LEN = 16 -- longest EggId is 9 chars
local PET_UID_MAX_LEN = 12 -- architecture 2 #7/#8
local DELETE_MAX = EconomyConfig.INVENTORY_CAP -- architecture 2 #8: 1..60 uids per call
local UID_MAX = 1e12 -- keeps tostring(uid) within PET_UID_MAX_LEN

local hatchedEvent = Instance.new("BindableEvent")

local PetService = {}
PetService.Hatched = hatchedEvent.Event -- (player: Player, eggId: T.EggId, results: { T.HatchedPet })

local rng = Random.new() -- the one server Random (engine seed); never sent to clients
local notifyRemote: RemoteEvent? = nil
local hatchResultRemote: RemoteEvent? = nil
local connections: { [Player]: { RBXScriptConnection } } = {}

-- Helpers ---------------------------------------------------------------------------------------------------

local function notify(player: Player, kind: Types.NotifyKind, text: string)
	if notifyRemote then
		local payload: Types.NotifyPayload = { kind = kind, text = text }
		notifyRemote:FireClient(player, payload)
	end
end

local function setAttr(player: Player, name: string, value: any)
	if player:GetAttribute(name) ~= value then
		player:SetAttribute(name, value)
	end
end

local function inventoryCount(data: ProfileData): number
	local n = 0
	for _ in data.pets.inventory do
		n += 1
	end
	return n
end

local function hasVip(player: Player, data: ProfileData): boolean
	local monetization = Deps.monetization()
	local fn = monetization and monetization.hasVip
	if fn then
		return fn(player)
	end
	return data.entitlements.vip == true
end

local function slotsFor(player: Player, data: ProfileData): number
	return EconomyConfig.petSlots(data.rebirths, hasVip(player, data))
end

local function worldUnlocked(data: ProfileData, world: number): boolean
	return world == 1 or (world == 2 and data.world2Unlocked == true)
end

-- Next free uid as a string; advances nextUid. Skips any uid already present (corrupt nextUid).
local function takeUid(d: ProfileData): string
	local n = math.floor(Guard.clampFinite(d.pets.nextUid, 1, UID_MAX, 1))
	while d.pets.inventory[tostring(n)] ~= nil do
		n += 1
	end
	d.pets.nextUid = n + 1
	return tostring(n)
end

-- Rolls `count` pets from `egg` (pure apart from the Random). Returns the pet ids in order.
local function rollPets(egg: Egg, count: number): { string }
	local ids = table.create(count)
	for i = 1, count do
		ids[i] = PetRoll.pick(egg.pets, rng)
	end
	return ids
end

-- How many of `petIds` would be kept (not auto-deleted).
local function keptCount(petIds: { string }, autoDelete: boolean): number
	local kept = 0
	for _, petId in petIds do
		if not (autoDelete and EconomyConfig.PETS[petId].rarity == EconomyConfig.AUTO_DELETE_RARITY) then
			kept += 1
		end
	end
	return kept
end

-- Inserts rolled pets into `d` (inside a DataService.update). Returns the HatchResult rows.
local function insertPets(d: ProfileData, petIds: { string }, autoDelete: boolean): { HatchedPet }
	local owned: { [string]: boolean } = {}
	for _, entry in d.pets.inventory do
		owned[entry.id] = true
	end
	local results: { HatchedPet } = {}
	for _, petId in petIds do
		local pet = EconomyConfig.PETS[petId]
		local deleted = autoDelete and pet.rarity == EconomyConfig.AUTO_DELETE_RARITY
		local uid: string? = nil
		if not deleted then
			uid = takeUid(d)
			d.pets.inventory[uid :: string] = { id = petId }
		end
		table.insert(results, {
			uid = uid,
			petId = petId,
			rarity = pet.rarity :: Types.Rarity,
			isNew = not owned[petId], -- "new" = not in the inventory right now (no ever-owned index in schema v1)
			autoDeleted = deleted,
			pity = false, -- coin eggs have no pity
		})
		owned[petId] = true
	end
	return results
end

local function sendResults(player: Player, eggId: Types.EggId, results: { HatchedPet })
	if hatchResultRemote then
		local payload: Types.HatchResultPayload = { eggId = eggId, pets = results }
		hatchResultRemote:FireClient(player, payload)
	end
	hatchedEvent:Fire(player, eggId, results)
	Deps.funnel(player, "FirstEgg")
end

-- Attributes ------------------------------------------------------------------------------------------------

local function refreshAttributes(player: Player)
	local data = Deps.data().getData(player)
	if data == nil then
		return
	end
	local ids: { string } = {}
	for _, uid in data.pets.equipped do
		local entry = data.pets.inventory[uid]
		if entry then
			table.insert(ids, entry.id)
		end
	end
	setAttr(player, Attr.EquippedPets, table.concat(ids, ","))
	setAttr(player, Attr.PetCount, inventoryCount(data))
	setAttr(player, Attr.PetSlots, slotsFor(player, data))
	setAttr(player, Attr.PityStarEgg, math.floor(Guard.clampFinite(data.pity.StarEgg, 0, 99, 0)))
	setAttr(player, Attr.PityGalaxyEgg, math.floor(Guard.clampFinite(data.pity.GalaxyEgg, 0, 99, 0)))
end

-- Drops equipped uids that are missing, duplicated or over the slot count (corrupt or old saves).
local function sanitizeEquipped(player: Player)
	local dataApi = Deps.data()
	local data = dataApi.getData(player)
	if data == nil then
		return
	end
	local slots = slotsFor(player, data)
	local clean: { string } = {}
	local seen: { [string]: boolean } = {}
	for _, uid in data.pets.equipped do
		if typeof(uid) == "string" and data.pets.inventory[uid] and not seen[uid] and #clean < slots then
			seen[uid] = true
			table.insert(clean, uid)
		end
	end
	if #clean ~= #data.pets.equipped then
		dataApi.update(player, function(d)
			d.pets.equipped = clean
		end)
	end
end

-- Public API ------------------------------------------------------------------------------------------------

-- Sum of equipped pet bonuses, before the x25 PetMult cap (MultiplierService applies the cap).
function PetService.getPetMultiplierSum(player: Player): number
	local data = Deps.data().getData(player)
	if data == nil then
		return 0
	end
	local slots = slotsFor(player, data)
	local sum = 0
	for i, uid in data.pets.equipped do
		if i > slots then
			break
		end
		local entry = data.pets.inventory[uid]
		local pet = entry and EconomyConfig.PETS[entry.id]
		if pet then
			sum += pet.bonus
		end
	end
	return sum
end

-- Inventory space left under INVENTORY_CAP (0 when full or not loaded).
function PetService.freeSlots(player: Player): number
	local data = Deps.data().getData(player)
	if data == nil then
		return 0
	end
	return math.max(0, EconomyConfig.INVENTORY_CAP - inventoryCount(data))
end

-- Hatches `count` (1, or 3 from Rebirth 2) of coin egg `eggId` at a stand. All checks are server-side.
function PetService.tryHatch(player: Player, eggId: Types.EggId, count: number): (boolean, string?)
	local dataApi = Deps.data()
	local data = dataApi.getData(player)
	if data == nil then
		return false, "NotLoaded"
	end
	if not Guard.isShortString(eggId, EGG_ID_MAX_LEN) then
		return false, "BadArgs"
	end
	local egg = EconomyConfig.EGGS[eggId]
	if egg == nil then
		return false, "UnknownEgg"
	end
	if egg.currency ~= "Coins" then
		return false, "RobuxEgg" -- Robux eggs only through RequestPurchase (architecture 2 #6)
	end
	-- Option A (D-021): coin eggs are not paid random items, so there is no PolicyService gate here; restricted
	-- players hatch coin eggs like everyone else. The PaidRandomAllowed gate applies to Robux eggs only (4d).
	if not Guard.isIntInRange(count, 1, EconomyConfig.HATCH_MULTI_COUNT) then
		return false, "BadArgs"
	end
	if count ~= 1 then
		if count ~= EconomyConfig.HATCH_MULTI_COUNT then
			return false, "BadArgs"
		end
		if data.rebirths < EconomyConfig.HATCH_MULTI_REBIRTHS then
			return false, "MultiLocked"
		end
	end
	if not worldUnlocked(data, egg.world) then
		return false, "WorldLocked"
	end
	local zone = Deps.zone()
	local nearStand = zone and zone.isNearEggStand
	if zone == nil or nearStand == nil then
		return false, "NoZone" -- fail closed until ZoneService.isNearEggStand lands (T-038)
	end
	if zone.getWorld(player) ~= egg.world or not nearStand(player, eggId) then
		return false, "TooFar"
	end
	local cost = egg.price * count
	if data.coins < cost then
		return false, "NotEnoughCoins"
	end
	local autoDelete = dataApi.getSetting(player, "AutoDeleteCommons")
	local petIds = rollPets(egg, count)
	if inventoryCount(data) + keptCount(petIds, autoDelete) > EconomyConfig.INVENTORY_CAP then
		return false, "InventoryFull" -- refused before charging
	end
	if not ActivityService.tryBegin(player, "Hatching") then
		return false, "Busy"
	end

	local results: { HatchedPet }? = nil
	dataApi.update(player, function(d)
		-- Re-check inside the update so cost, roll and insert are one step.
		if
			d.coins < cost
			or inventoryCount(d) + keptCount(petIds, autoDelete) > EconomyConfig.INVENTORY_CAP
		then
			return
		end
		d.coins -= cost
		results = insertPets(d, petIds, autoDelete)
	end)
	task.delay(EconomyConfig.HATCH_LOCK_SEC, ActivityService.finish, player, "Hatching")
	if results == nil then
		return false, "NotEnoughCoins"
	end

	refreshAttributes(player)
	sendResults(player, eggId, results)
	Deps.economy(player, "Sink", cost, "Egg")
	return true
end

-- Free hatch with no cost, stand or activity check (server callers only: daily Day-4 reward, later receipts).
-- Lean v1: coin eggs only; Robux eggs (pity, restricted fallback) arrive with T-073.
function PetService.grantEgg(player: Player, eggId: Types.EggId, count: number): boolean
	local dataApi = Deps.data()
	local data = dataApi.getData(player)
	local egg = EconomyConfig.EGGS[eggId]
	if data == nil or egg == nil or not Guard.isIntInRange(count, 1, EconomyConfig.HATCH_MULTI_COUNT) then
		return false
	end
	if egg.currency ~= "Coins" then
		return false -- TODO(T-073): Robux egg roll with pity and the restrictedGrant fallback
	end
	local autoDelete = dataApi.getSetting(player, "AutoDeleteCommons")
	local petIds = rollPets(egg, count)
	local results: { HatchedPet }? = nil
	dataApi.update(player, function(d)
		if inventoryCount(d) + keptCount(petIds, autoDelete) > EconomyConfig.INVENTORY_CAP then
			return
		end
		results = insertPets(d, petIds, autoDelete)
	end)
	if results == nil then
		return false
	end
	refreshAttributes(player)
	sendResults(player, eggId, results)
	return true
end

-- Equips or unequips one owned pet. Equip needs a free slot. No-op (true) if nothing changes.
function PetService.setEquipped(player: Player, petUid: string, equip: boolean): (boolean, string?)
	local dataApi = Deps.data()
	local data = dataApi.getData(player)
	if data == nil then
		return false, "NotLoaded"
	end
	if not Guard.isShortString(petUid, PET_UID_MAX_LEN) or typeof(equip) ~= "boolean" then
		return false, "BadArgs"
	end
	if data.pets.inventory[petUid] == nil then
		return false, "NotOwned"
	end
	local index = table.find(data.pets.equipped, petUid)
	if equip == (index ~= nil) then
		return true -- unchanged
	end
	if equip and #data.pets.equipped >= slotsFor(player, data) then
		return false, "NoSlot"
	end
	dataApi.update(player, function(d)
		if equip then
			table.insert(d.pets.equipped, petUid)
		else
			local i = table.find(d.pets.equipped, petUid)
			if i then
				table.remove(d.pets.equipped, i)
			end
		end
	end)
	refreshAttributes(player)
	MultiplierService.refresh(player) -- CR-c: M follows the equipped pets at once
	return true
end

-- Deletes 1..60 owned pets (unequipping them first). `petUids` must be a plain array of unique uid strings.
function PetService.deletePets(player: Player, petUids: { string }): (boolean, string?)
	local dataApi = Deps.data()
	local data = dataApi.getData(player)
	if data == nil then
		return false, "NotLoaded"
	end
	if typeof(petUids) ~= "table" then
		return false, "BadArgs"
	end
	local n = 0
	for key in petUids :: { [any]: any } do
		n += 1
		if n > DELETE_MAX or not Guard.isIntInRange(key, 1, DELETE_MAX) then
			return false, "BadArgs" -- too many entries, or a non-array key
		end
	end
	if n == 0 or n ~= #petUids then
		return false, "BadArgs"
	end
	local seen: { [string]: boolean } = {}
	for _, uid in petUids do
		if not Guard.isShortString(uid, PET_UID_MAX_LEN) or seen[uid] then
			return false, "BadArgs"
		end
		if data.pets.inventory[uid] == nil then
			return false, "NotOwned"
		end
		seen[uid] = true
	end
	dataApi.update(player, function(d)
		local keep: { string } = {}
		for _, uid in d.pets.equipped do
			if not seen[uid] then
				table.insert(keep, uid)
			end
		end
		d.pets.equipped = keep
		for uid in seen do
			d.pets.inventory[uid] = nil
		end
	end)
	refreshAttributes(player)
	MultiplierService.refresh(player) -- CR-c: deleting an equipped pet changes M
	return true
end

-- Lifecycle -------------------------------------------------------------------------------------------------

local HATCH_TEXT: { [string]: string } = {
	NotEnoughCoins = "Not enough coins",
	InventoryFull = `Pet inventory full ({EconomyConfig.INVENTORY_CAP}). Delete some pets first`,
	MultiLocked = `Hatch x{EconomyConfig.HATCH_MULTI_COUNT} unlocks at Rebirth {EconomyConfig.HATCH_MULTI_REBIRTHS}`,
	TooFar = "Walk closer to the egg!",
	WorldLocked = "Unlocks in World 2",
}

local function onLoaded(player: Player)
	sanitizeEquipped(player)
	refreshAttributes(player)
	if connections[player] then
		return
	end
	-- Slots grow with Rebirths (3, 8) and VIP; both attributes have one writer outside Gameplay's layer order.
	local function onSlotsChanged()
		refreshAttributes(player)
		MultiplierService.refresh(player)
	end
	connections[player] = {
		player:GetAttributeChangedSignal(Attr.Rebirths):Connect(onSlotsChanged),
		player:GetAttributeChangedSignal(Attr.Vip):Connect(onSlotsChanged),
	}
end

local function onRemoving(player: Player)
	local list = connections[player]
	if list then
		for _, conn in list do
			conn:Disconnect()
		end
		connections[player] = nil
	end
end

function PetService.Init() end

function PetService.Start()
	notifyRemote = Remotes.getEvent("Notify")
	hatchResultRemote = Remotes.getEvent("HatchResult")
	local dataApi = Deps.data()

	RateLimit.connect("HatchEgg", function(player: Player, eggId: any, count: any)
		if not dataApi.isLoaded(player) or not Guard.isShortString(eggId, EGG_ID_MAX_LEN) then
			return
		end
		if not Guard.isIntInRange(count, 1, EconomyConfig.HATCH_MULTI_COUNT) then
			return
		end
		local ok, reason = PetService.tryHatch(player, eggId, count)
		if ok or reason == nil then
			return
		end
		local egg = EconomyConfig.EGGS[eggId]
		local text = HATCH_TEXT[reason]
		if reason == "NotEnoughCoins" and egg then
			text = `Not enough coins (need {NumberFormat.abbreviate(egg.price * count)})`
		end
		if text then
			notify(player, "Error", text)
		end
	end)

	RateLimit.connect("EquipPet", function(player: Player, petUid: any, equip: any)
		if not dataApi.isLoaded(player) or not Guard.isShortString(petUid, PET_UID_MAX_LEN) then
			return
		end
		if typeof(equip) ~= "boolean" then
			return
		end
		local ok, reason = PetService.setEquipped(player, petUid, equip)
		if not ok and reason == "NoSlot" then
			notify(player, "Error", "No free pet slot. Unequip a pet first")
		end
	end)

	RateLimit.connect("DeletePets", function(player: Player, petUids: any)
		if not dataApi.isLoaded(player) or typeof(petUids) ~= "table" then
			return
		end
		PetService.deletePets(player, petUids)
	end)

	dataApi.ProfileLoaded:Connect(onLoaded)
	Players.PlayerRemoving:Connect(onRemoving)
	for _, player in Players:GetPlayers() do
		if dataApi.isLoaded(player) then
			onLoaded(player)
		end
	end
end

return PetService
