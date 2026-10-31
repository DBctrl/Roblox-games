--!strict
-- T-046 / QA-5: equip, unequip and delete must refresh M at once (CR-c condition, D-032; architecture 1a).
-- Owned by qa. Needs a real Player (Play, F5) with a throwaway account or Studio's mock DataStore.
--
-- Architecture 1b lists no server-callable equip/delete function (only the EquipPet/DeletePets remote handlers),
-- so this spec probes for one (QA-F8 asks gameplay to expose it):
--   equip:  PetService.setEquipped | tryEquip | equip   (player, petUid, equip: boolean) -> (boolean, string?)
--   delete: PetService.deletePets | tryDelete            (player, petUids: { string })   -> (boolean, string?)
-- If none exists the spec SKIPs; `python3 -I tests/static/check_authority.py` still checks QA-5 statically.
-- Checks both the call (MultiplierService.refresh wrapped and counted) and the outcome (M = 1 + bonus with
-- rebirths 0, no boosts, no paid tier, no VIP).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local TestKit = require(ReplicatedStorage:WaitForChild("QaTests"):WaitForChild("TestKit"))

local PLAYER_WAIT_SEC = 20

local function waitForLoadedPlayer(): Player?
	local deadline = os.clock() + PLAYER_WAIT_SEC
	while os.clock() < deadline do
		for _, p in Players:GetPlayers() do
			if p:GetAttribute("DataLoaded") == true then
				return p
			end
		end
		task.wait(0.25)
	end
	return nil
end

local function firstFn(mod: any, names: { string }): ((...any) -> ...any)?
	for _, n in names do
		if type(mod[n]) == "function" then
			return mod[n]
		end
	end
	return nil
end

return function(t: TestKit.Suite)
	local Server = ServerScriptService:FindFirstChild("Server")
	local Shared = ReplicatedStorage:FindFirstChild("Shared")
	local PetService = TestKit.tryRequire(Server, { "Gameplay", "PetService" }) :: any
	local MultiplierService = TestKit.tryRequire(Server, { "Gameplay", "MultiplierService" }) :: any
	local DataService = TestKit.tryRequire(Server, { "Data", "DataService" }) :: any
	local ProfileSchema = TestKit.tryRequire(Server, { "Data", "Util", "ProfileSchema" }) :: any
	local E = TestKit.tryRequire(Shared, { "Gameplay", "EconomyConfig" }) :: any

	if
		PetService == nil
		or MultiplierService == nil
		or DataService == nil
		or ProfileSchema == nil
		or E == nil
	then
		t.skip("QA-5 equip/unequip/delete refresh", "PetService (T-028) or a dependency not merged")
		return
	end
	local equipFn = firstFn(PetService, { "setEquipped", "tryEquip", "equip" })
	local deleteFn = firstFn(PetService, { "deletePets", "tryDelete" })
	if equipFn == nil then
		t.skip(
			"QA-5 equip/unequip/delete refresh",
			"no server-callable equip function (QA-F8); see check_authority"
		)
		return
	end
	-- Two real pets with a bonus > 0, by id order.
	local ids = {}
	for id, pet in E.PETS do
		if type(pet.bonus) == "number" and pet.bonus > 0 then
			table.insert(ids, id)
		end
	end
	table.sort(ids)
	if #ids < 1 then
		t.skip("QA-5 equip/unequip/delete refresh", "EconomyConfig.PETS is empty (T-027 not merged)")
		return
	end
	local petId = ids[1]
	local bonus = E.PETS[petId].bonus

	local player = waitForLoadedPlayer()
	if player == nil then
		t.skip("QA-5 equip/unequip/delete refresh", "no loaded Player (run with Play, F5)")
		return
	end
	local p = player :: Player
	local snapshot = ProfileSchema.deepCopy(DataService.getData(p))

	local calls = 0
	local originalRefresh = MultiplierService.refresh
	-- A frozen service table can't be wrapped; then only the outcome (M) is checked.
	local wrapped = pcall(function()
		MultiplierService.refresh = function(target: Player, ...)
			if target == p then
				calls += 1
			end
			return originalRefresh(target, ...)
		end
	end)

	local ok, err = pcall(function()
		DataService.update(p, function(d: any)
			d.rebirths = 0
			d.entitlements.paidTier = 0
			d.entitlements.vip = false
			d.boosts = { hypeSec = 0, coinSec = 0, speedSec = 0 }
			d.pets =
				{ inventory = { ["1"] = { id = petId }, ["2"] = { id = petId } }, equipped = {}, nextUid = 3 }
		end)
		originalRefresh(p)

		t.test("equip calls MultiplierService.refresh and M includes the pet bonus", function()
			calls = 0
			local done = equipFn(p, "1", true)
			t.ok(done ~= false, "equip accepted")
			t.ok(not wrapped or calls >= 1, `MultiplierService.refresh calls after equip: {calls}`)
			t.near(MultiplierService.getMpMultiplier(p), 1 + bonus, "M after equip", 1e-9)
		end)

		t.test("unequip calls MultiplierService.refresh and M drops back", function()
			calls = 0
			local done = equipFn(p, "1", false)
			t.ok(done ~= false, "unequip accepted")
			t.ok(not wrapped or calls >= 1, `MultiplierService.refresh calls after unequip: {calls}`)
			t.near(MultiplierService.getMpMultiplier(p), 1, "M after unequip", 1e-9)
		end)

		t.test("equip of a pet the player does not own is refused and does not change M", function()
			local done = equipFn(p, "999", true)
			t.ok(done == false, "equip of unknown uid refused")
			t.near(MultiplierService.getMpMultiplier(p), 1, "M unchanged", 1e-9)
		end)

		if deleteFn == nil then
			t.skip("delete of an equipped pet refreshes M", "no server-callable delete function (QA-F8)")
		else
			t.test("deleting an equipped pet unequips it, refreshes and drops M", function()
				equipFn(p, "2", true)
				calls = 0
				local done = (deleteFn :: any)(p, { "2" })
				t.ok(done ~= false, "delete accepted")
				t.ok(not wrapped or calls >= 1, `MultiplierService.refresh calls after delete: {calls}`)
				local d = DataService.getData(p)
				t.eq(d.pets.inventory["2"], nil, "pet removed")
				t.eq(table.find(d.pets.equipped, "2"), nil, "pet no longer equipped")
				t.near(MultiplierService.getMpMultiplier(p), 1, "M after delete", 1e-9)
			end)
		end
	end)

	if wrapped then
		MultiplierService.refresh = originalRefresh
	end
	DataService.update(p, function(data: any)
		for k in data do
			data[k] = nil
		end
		for k, v in snapshot :: any do
			data[k] = ProfileSchema.deepCopy(v)
		end
	end)
	originalRefresh(p)
	if not ok then
		error(err)
	end
end
