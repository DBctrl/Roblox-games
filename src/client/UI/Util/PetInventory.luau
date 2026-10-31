--!strict
-- Read-only view of the local player's pets for the UI (helper, not a controller). Owned by systems-programmer.
--
-- Reads `Types.PlayerAttr.PetInventory` (CR-S2a, D-051, architecture 1e), written only by PetService:
--   comma-separated `uid:petId:e` entries, e = "1" if equipped, else "0", sorted by numeric uid, no spaces,
--   "" when empty, at most INVENTORY_HARD_CAP (66) entries. Example "1:PuffPup:1,2:BubbleBunny:0".
-- While the attribute is missing (not written yet) or malformed, `entries()` returns nil and the UI says the
-- inventory is syncing; "you own" ticks fall back to EquippedPets plus pets hatched this session.
-- Everything here is display only. The server re-checks every uid it receives.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Types =
	require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Contracts"):WaitForChild("Types"))

local GameData = require(script.Parent:WaitForChild("GameData"))

local Attr = Types.PlayerAttr

local PetInventory = {}

PetInventory.ATTR = Attr.PetInventory

local MAX_UID_LEN = 12
local MAX_ID_LEN = 40

export type Entry = { uid: string, petId: string, equipped: boolean }

local sessionHatched: { [string]: boolean } = {}

-- Parses the PetInventory attribute; nil if it is missing or malformed. Malformed: more than
-- INVENTORY_HARD_CAP entries, an entry that is not `uid:petId:0|1`, a uid that is not a positive integer, or
-- uids not strictly increasing (the writer sorts by numeric uid, so a duplicate uid is malformed too).
function PetInventory.entries(): { Entry }?
	local raw = Players.LocalPlayer:GetAttribute(PetInventory.ATTR)
	if type(raw) ~= "string" then
		return nil
	end
	local out: { Entry } = {}
	if raw == "" then
		return out
	end
	local items = string.split(raw, ",")
	if #items > GameData.inventoryHardCap() then
		return nil
	end
	local lastUid = 0
	for _, item in items do
		local parts = string.split(item, ":")
		local uid, petId, flag = parts[1], parts[2], parts[3]
		if
			#parts ~= 3
			or #uid > MAX_UID_LEN
			or string.match(uid, "^[1-9]%d*$") == nil
			or petId == ""
			or #petId > MAX_ID_LEN
			or (flag ~= "0" and flag ~= "1")
		then
			return nil
		end
		local uidNum = tonumber(uid) :: number
		if uidNum <= lastUid then
			return nil
		end
		lastUid = uidNum
		table.insert(out, { uid = uid, petId = petId, equipped = flag == "1" })
	end
	return out
end

-- Pet ids the player owns (for "you own" ticks).
function PetInventory.ownedIds(): { [string]: boolean }
	local owned: { [string]: boolean } = {}
	local entries = PetInventory.entries()
	if entries then
		for _, entry in entries do
			owned[entry.petId] = true
		end
		return owned
	end
	local equipped = Players.LocalPlayer:GetAttribute(Attr.EquippedPets)
	if type(equipped) == "string" and equipped ~= "" then
		for _, petId in string.split(equipped, ",") do
			owned[petId] = true
		end
	end
	for petId in sessionHatched do
		owned[petId] = true
	end
	return owned
end

-- EggController records kept (not auto-deleted) hatch results so the fallback ticks stay right.
function PetInventory.noteHatched(petId: string)
	if #petId <= MAX_ID_LEN then
		sessionHatched[petId] = true
	end
end

-- Fires `callback` whenever the inventory or the equipped list changes.
function PetInventory.onChanged(callback: () -> ()): { RBXScriptConnection }
	local player = Players.LocalPlayer
	return {
		player:GetAttributeChangedSignal(PetInventory.ATTR):Connect(callback),
		player:GetAttributeChangedSignal(Attr.EquippedPets):Connect(callback),
		player:GetAttributeChangedSignal(Attr.PetCount):Connect(callback),
	}
end

return table.freeze(PetInventory)
