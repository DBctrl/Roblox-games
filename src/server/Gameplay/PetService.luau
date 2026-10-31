--!strict
-- PetService (architecture 1b #12 and 4b, layer L1). Owned by gameplay-programmer.
-- Coin-egg hatching (`HatchEgg`), the pet inventory, equip/unequip (`EquipPet`) and multi-delete (`DeletePets`).
-- The client sends only an egg id + count, or pet uids; price, odds, roll, slots and ownership are server-side.
-- The roll uses one server `Random` and the weights in EconomyConfig.EGGS (the same table the egg UI shows).
-- Cost, roll and inventory insert happen in ONE DataService.update, so a hatch is all-or-nothing.
-- Every equip, unequip or delete ends with MultiplierService.refresh (CR-c, D-032), so M is never stale.
-- Sole writer of EquippedPets, PetInventory, PetCount, PetSlots, PityStarEgg and PityGalaxyEgg.
-- Receipt grants (T-053, T-073), registered with MonetizationService in Start(): FixedPet (Ring Light Retriever),
-- StarterPack (Sparkle Pup + 30 min Hype + Rookie Shades, no coins, pod or egg) and RobuxEgg. Paid pets may take
-- the inventory past INVENTORY_CAP up to INVENTORY_HARD_CAP so no paid pet is lost; at the hard cap the grant
-- returns false (receipt stays unprocessed and retries after the player makes room).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ActivityService = require(script.Parent.ActivityService)
local Deps = require(script.Parent.Util.Deps)
local EconomyConfig = require(ReplicatedStorage.Shared.Gameplay.EconomyConfig)
local Guard = require(script.Parent.Util.Guard)
local MultiplierService = require(script.Parent.MultiplierService)
local NumberFormat = require(ReplicatedStorage.Shared.Contracts.NumberFormat)
local PetRoll = require(script.Parent.Util.PetRoll)
local ProductCatalog = require(ReplicatedStorage.Shared.Contracts.ProductCatalog)
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
local UID_MAX = 1e12 - 1 -- largest 12-digit uid: tostring(uid) never exceeds PET_UID_MAX_LEN (T-095)

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

-- PetInventory attribute (architecture 1e, CR-S2a, D-051): "uid:petId:e" entries, e = 1 equipped / 0 not,
-- sorted by numeric uid, "" when empty, at most INVENTORY_HARD_CAP entries. Display only for the client.
local function inventoryString(data: ProfileData): string
	local isEquipped: { [string]: boolean } = {}
	for _, uid in data.pets.equipped do
		isEquipped[uid] = true
	end
	local uids: { string } = {}
	for uid in data.pets.inventory do
		table.insert(uids, uid)
	end
	table.sort(uids, function(a: string, b: string): boolean
		local na, nb = tonumber(a), tonumber(b)
		if na and nb and na ~= nb then
			return na < nb
		end
		if (na == nil) ~= (nb == nil) then
			return na ~= nil -- numeric uids first (corrupt saves only)
		end
		return a < b
	end)
	local parts: { string } = {}
	for i, uid in uids do
		if i > EconomyConfig.INVENTORY_HARD_CAP then
			break
		end
		parts[i] = `{uid}:{data.pets.inventory[uid].id}:{if isEquipped[uid] then "1" else "0"}`
	end
	return table.concat(parts, ",")
end

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
	setAttr(player, Attr.PetInventory, inventoryString(data))
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

-- Free hatch with no cost, stand or activity check (server callers only: the daily Day-4 reward).
-- Coin eggs only: Robux eggs are granted only through their receipt grant (grantRobuxEgg), never for free.
function PetService.grantEgg(player: Player, eggId: Types.EggId, count: number): boolean
	local dataApi = Deps.data()
	local data = dataApi.getData(player)
	local egg = EconomyConfig.EGGS[eggId]
	if data == nil or egg == nil or not Guard.isIntInRange(count, 1, EconomyConfig.HATCH_MULTI_COUNT) then
		return false
	end
	if egg.currency ~= "Coins" then
		return false -- no free Robux egg hatch, ever (GDD 8g; D-016 #5)
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

-- Receipt grants (T-053, T-073) ---------------------------------------------------------------------------
-- Each runs inside MonetizationService's one DataService.update (architecture 3c step 4): it mutates only `data`,
-- never yields or calls DataService, and returns false WITHOUT touching `data` when it cannot grant. Receipt
-- dedupe is MonetizationService's (receipt id stored in the same update), so a grant runs once per receipt.
-- Attribute writes, Notify and HatchResult are deferred until after that update. No grant touches coins.

-- Paid pets that still fit under the hard cap (paid receipts may pass INVENTORY_CAP by up to 6, 4b).
local function paidRoom(data: ProfileData, count: number): boolean
	return inventoryCount(data) + count <= EconomyConfig.INVENTORY_HARD_CAP
end

local function afterGrant(player: Player, text: string?)
	task.defer(function()
		if player.Parent ~= Players then
			return
		end
		refreshAttributes(player)
		MultiplierService.refresh(player)
		if text then
			notify(player, "Success", text)
		end
	end)
end

local function refuseFull(player: Player)
	task.defer(
		notify,
		player,
		"Error",
		"Pet inventory is full. Delete some pets and rejoin to receive your purchase"
	)
end

local function grantFixedPet(player: Player, key: Types.ProductKey, data: ProfileData): boolean
	local entry = ProductCatalog.get(key)
	local petId = entry and entry.petId
	local pet = petId and EconomyConfig.PETS[petId]
	if entry == nil or not entry.onSale or entry.grantKind ~= "FixedPet" or petId == nil or pet == nil then
		return false -- Neon Pup is not on sale (D-038)
	end
	if not paidRoom(data, 1) then
		refuseFull(player)
		return false
	end
	data.pets.inventory[takeUid(data)] = { id = petId }
	afterGrant(player, `You got {pet.name}!`)
	return true
end

-- Starter Pack: Sparkle Pup + 30 min Hype Snack + Rookie Shades + the once flag. No coins, no pod, no egg.
-- The once rule is a prompt gate (MonetizationService); a second receipt that still arrives gets the same contents
-- again, so Robux is never taken for nothing (D-063).
local function grantStarterPack(player: Player, key: Types.ProductKey, data: ProfileData): boolean
	local entry = ProductCatalog.get(key)
	local petId = entry and entry.petId
	local hypeSec = entry and entry.hypeSec
	if
		entry == nil
		or not entry.onSale
		or entry.grantKind ~= "StarterPack"
		or petId == nil
		or EconomyConfig.PETS[petId] == nil
		or hypeSec == nil
	then
		return false
	end
	if not paidRoom(data, 1) then
		refuseFull(player)
		return false
	end
	if data.entitlements.starterPack then
		print(`[PetService] repeat Starter Pack receipt for user {player.UserId}: contents granted again`)
	end
	data.pets.inventory[takeUid(data)] = { id = petId }
	data.boosts.hypeSec = Guard.clampFinite(data.boosts.hypeSec, 0, math.huge, 0) + hypeSec -- paid time never dropped
	data.entitlements.cosmetics.RookieShades = true
	data.entitlements.starterPack = true
	afterGrant(player, "Starter Pack unlocked!")
	return true
end

-- Robux egg receipt (T-073). Allowed players: `count` server rolls in order with the saved pity counter (true odds
-- at the pity hatch). Restricted players (PaidRandomAllowed false, fail closed): the stated fixed pet from
-- ProductCatalog.restrictedGrant (x3 for a 3-pack), no roll, pity unchanged, logged. Never nothing (D-016 #4).
local function grantRobuxEgg(player: Player, key: Types.ProductKey, data: ProfileData): boolean
	local entry = ProductCatalog.get(key)
	local eggId = entry and entry.eggId
	local egg = eggId and EconomyConfig.EGGS[eggId]
	local count = entry and entry.count
	if
		entry == nil
		or not entry.onSale
		or entry.grantKind ~= "RobuxEgg"
		or egg == nil
		or egg.currency ~= "Robux"
		or count == nil
		or not Guard.isIntInRange(count, 1, EconomyConfig.HATCH_MULTI_COUNT)
	then
		return false
	end
	local id = eggId :: Types.EggId
	local restricted = not Deps.paidRandomAllowed(player)
	local petIds: { string } = {}
	local forcedList: { boolean } = {}
	local newPity: number? = nil
	if restricted then
		local fixed = ProductCatalog.restrictedGrant(entry.key)
		if EconomyConfig.PETS[fixed.petId] == nil then
			return false
		end
		for i = 1, fixed.count do
			petIds[i] = fixed.petId
			forcedList[i] = false
		end
	else
		local pity = Guard.clampFinite(data.pity[id], 0, 1e6, 0)
		for i = 1, count do
			local petId, nextPity, forced = PetRoll.pickWithPity(egg, pity, rng)
			petIds[i] = petId
			forcedList[i] = forced
			pity = nextPity
		end
		newPity = pity
	end
	if not paidRoom(data, #petIds) then
		refuseFull(player)
		return false -- nothing written: the rolls above are discarded with the unprocessed receipt
	end

	local owned: { [string]: boolean } = {}
	for _, row in data.pets.inventory do
		owned[row.id] = true
	end
	local results: { HatchedPet } = {}
	for i, petId in petIds do
		local uid = takeUid(data)
		data.pets.inventory[uid] = { id = petId }
		table.insert(results, {
			uid = uid,
			petId = petId,
			rarity = EconomyConfig.PETS[petId].rarity :: Types.Rarity,
			isNew = not owned[petId],
			autoDeleted = false, -- paid pets are never auto-deleted
			pity = forcedList[i],
		})
		owned[petId] = true
	end
	if newPity ~= nil then
		data.pity[id] = newPity
	else
		print(
			`[PetService] restricted Robux egg receipt: user {player.UserId} key {key} -> {#petIds} x {petIds[1]}`
		)
	end
	local pityAfter = if newPity ~= nil then newPity else Guard.clampFinite(data.pity[id], 0, 1e6, 0)
	-- QA-14: `data` is MonetizationService's copy, and this fn returns before anyone knows whether the copy is
	-- committed. The deferred reveal runs after that update and only goes out if every granted pet is in the LIVE
	-- profile, so a refused or released receipt sends no HatchResult and fires no Hatched (the retry reveals once).
	task.defer(function()
		if player.Parent ~= Players then
			return
		end
		local live = Deps.data().getData(player)
		if live == nil then
			return
		end
		for _, pet in results do
			local row = live.pets.inventory[pet.uid]
			if row == nil or row.id ~= pet.petId then
				return -- not committed: say nothing to the client and count no hatch
			end
		end
		refreshAttributes(player)
		MultiplierService.refresh(player)
		if hatchResultRemote then
			local payload: Types.HatchResultPayload = { eggId = id, pets = results, pity = pityAfter }
			hatchResultRemote:FireClient(player, payload)
		end
		hatchedEvent:Fire(player, id, results)
		Deps.funnel(player, "FirstEgg")
	end)
	return true
end

-- Exposed for qa's GDD 8g firewall test (walks every grant fn with a fake profile).
PetService.grants = table.freeze({
	FixedPet = grantFixedPet,
	StarterPack = grantStarterPack,
	RobuxEgg = grantRobuxEgg,
})

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

	Deps.registerGrant("FixedPet", grantFixedPet)
	Deps.registerGrant("StarterPack", grantStarterPack)
	Deps.registerGrant("RobuxEgg", grantRobuxEgg)

	dataApi.ProfileLoaded:Connect(onLoaded)
	Players.PlayerRemoving:Connect(onRemoving)
	for _, player in Players:GetPlayers() do
		if dataApi.isLoaded(player) then
			onLoaded(player)
		end
	end
end

return PetService
