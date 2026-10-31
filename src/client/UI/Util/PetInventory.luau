--!strict
-- Read-only view of the local player's pets for the UI (helper, not a controller). Owned by systems-programmer.
--
-- The client needs pet uids to equip and delete, but architecture 1e only replicates `EquippedPets` (pet ids)
-- and `PetCount`. Contract request CR-S2a asks for one more PetService attribute:
--   `PetInventory` (string): comma-separated `uid:petId:e` entries, e = 1 if equipped, else 0.
--   Example "1:PuffPup:1,2:BubbleBunny:0". Rewritten after every hatch, grant, equip, unequip and delete.
-- Until it exists (TODO(CR-S2a)), `entries()` returns nil and the UI says the inventory is syncing; "you own"
-- ticks fall back to EquippedPets plus pets hatched this session (from HatchResult).
-- Everything here is display only. The server re-checks every uid it receives.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Types =
	require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Contracts"):WaitForChild("Types"))

local Attr = Types.PlayerAttr

local PetInventory = {}

-- TODO(CR-S2a): use Types.PlayerAttr.PetInventory once integration adds it.
PetInventory.ATTR = ((Attr :: any).PetInventory :: string?) or "PetInventory"

local MAX_ENTRIES = 80 -- hard cap 66 plus slack; anything longer is ignored
local MAX_UID_LEN = 12
local MAX_ID_LEN = 40

export type Entry = { uid: string, petId: string, equipped: boolean }

local sessionHatched: { [string]: boolean } = {}

-- Parses the PetInventory attribute; nil if it is missing or malformed.
function PetInventory.entries(): { Entry }?
	local raw = Players.LocalPlayer:GetAttribute(PetInventory.ATTR)
	if type(raw) ~= "string" then
		return nil
	end
	local out: { Entry } = {}
	if raw == "" then
		return out
	end
	for _, item in string.split(raw, ",") do
		local parts = string.split(item, ":")
		local uid, petId, flag = parts[1], parts[2], parts[3]
		if
			#parts ~= 3
			or uid == ""
			or #uid > MAX_UID_LEN
			or petId == ""
			or #petId > MAX_ID_LEN
			or (flag ~= "0" and flag ~= "1")
		then
			return nil
		end
		table.insert(out, { uid = uid, petId = petId, equipped = flag == "1" })
		if #out > MAX_ENTRIES then
			return nil
		end
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
