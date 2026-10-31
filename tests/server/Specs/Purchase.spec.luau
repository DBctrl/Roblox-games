--!strict
-- T-081: purchase flow. ProcessReceipt dedupe, grant failure, save failure, absent player, receipts before FirstWin,
-- D-019 ladder receipts, boost cap, restricted-player Robux egg receipts. Owned by qa.
-- Written against docs/architecture.md v1.3 section 3c (ProcessReceipt steps 1-5), 4d, 4e, 4f; not against code.
--
-- Needs a real Player (Play, F5) with a throwaway account or Studio's mock DataStore: it grants test pets and Hype
-- time to that profile (it restores the paid tier, Hype seconds and FirstWin it changes, and deletes the test pets
-- when PetService.deletePets exists). SKIPs in Run mode or while MonetizationService (T-056) is not merged.
--
-- Test seams (QA-F9; not in architecture 1b yet, so this spec probes for them and SKIPs what is missing):
--   processReceipt(receiptInfo) -> Enum.ProductPurchaseDecision   the exact fn assigned to ProcessReceipt
--   grantEntry(player, entry, purchaseId) -> Enum.ProductPurchaseDecision
--       steps 2, 4 and 5 for a catalog entry, so receipts can be tested while every product id is placeholder 0
--   getGrant(kind) -> grantFn?                                     the registry read behind registerGrant
-- Fault injection patches module fields at call time: DataService.saveAndConfirm (save failure),
-- ComplianceService.paidRandomAllowed (restricted player) and PetRoll.pick (a roll must not happen). It works only
-- if the services call those through the module table (`DataService.saveAndConfirm(...)`, `Deps.compliance()`),
-- not through a local captured at require time; the failure text says so.

local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local TestKit = require(ReplicatedStorage:WaitForChild("QaTests"):WaitForChild("TestKit"))

local Granted = Enum.ProductPurchaseDecision.PurchaseGranted
local NotYet = Enum.ProductPurchaseDecision.NotProcessedYet
local HYPE_TOL = 5 -- Hype seconds tick down while online; allow a few seconds of drift between reads

local function newId(tag: string): string
	return `qa-{tag}-{HttpService:GenerateGUID(false)}`
end

return function(t: TestKit.Suite)
	local Server = ServerScriptService:FindFirstChild("Server")
	local Shared = ReplicatedStorage:FindFirstChild("Shared")
	local DataService = TestKit.tryRequire(Server, { "Data", "DataService" }) :: any
	local Monetization = TestKit.tryRequire(Server, { "Data", "MonetizationService" }) :: any
	local Compliance = TestKit.tryRequire(Server, { "Data", "ComplianceService" }) :: any
	local PetService = TestKit.tryRequire(Server, { "Gameplay", "PetService" }) :: any
	local PetRoll = TestKit.tryRequire(Server, { "Gameplay", "Util", "PetRoll" }) :: any
	local Catalog = TestKit.tryRequire(Shared, { "Contracts", "ProductCatalog" }) :: any
	local EconomyConfig = TestKit.tryRequire(Shared, { "Gameplay", "EconomyConfig" }) :: any

	if Monetization == nil or DataService == nil or Catalog == nil then
		t.skip(
			"all purchase-flow tests",
			"MonetizationService (T-056), DataService or ProductCatalog not merged"
		)
		return
	end
	local players = TestKit.loadedPlayers(1)
	if #players == 0 then
		t.skip("all purchase-flow tests", "no Player with DataLoaded (use Play, not Run)")
		return
	end
	local plr: Player = players[1]

	local processReceipt =
		TestKit.firstFn(Monetization, { "processReceipt", "ProcessReceipt", "_processReceipt" })
	local grantEntry = TestKit.firstFn(Monetization, { "grantEntry", "_grantEntry", "processEntry" })
	local getGrant = TestKit.firstFn(Monetization, { "getGrant", "_getGrant" })

	local function data(): any
		local d = DataService.getData(plr)
		assert(d, "getData returned nil for a loaded player")
		return d
	end
	local function receiptCount(id: string): number
		local n = 0
		for _, r in data().receipts do
			if r == id then
				n += 1
			end
		end
		return n
	end
	local function petCount(petId: string?): number
		local n = 0
		for _, p in data().pets.inventory do
			if petId == nil or p.id == petId then
				n += 1
			end
		end
		return n
	end
	local function invKeys(): { [string]: boolean }
		local s = {}
		for uid in data().pets.inventory do
			s[tostring(uid)] = true
		end
		return s
	end
	-- Removes pets added since `before` (keeps the throwaway profile small). Best effort.
	local function cleanupPets(before: { [string]: boolean })
		local del = PetService and TestKit.firstFn(PetService, { "deletePets" })
		if del == nil then
			return
		end
		local added = {}
		for uid in invKeys() do
			if not before[uid] then
				table.insert(added, uid)
			end
		end
		if #added > 0 then
			pcall(del, plr, added)
		end
	end
	-- Sets profile fields for one test and returns a restore. Only fields this spec owns the meaning of.
	local function setFields(fields: { paidTier: number?, hypeSec: number?, firstWin: boolean? }): () -> ()
		local d = data()
		local old = { paidTier = d.entitlements.paidTier, hypeSec = d.boosts.hypeSec, firstWin = d.firstWin }
		local oldAttr = plr:GetAttribute("FirstWin")
		DataService.update(plr, function(p: any)
			if fields.paidTier ~= nil then
				p.entitlements.paidTier = fields.paidTier
			end
			if fields.hypeSec ~= nil then
				p.boosts.hypeSec = fields.hypeSec
			end
			if fields.firstWin ~= nil then
				p.firstWin = fields.firstWin
			end
		end)
		if fields.firstWin ~= nil then
			plr:SetAttribute("FirstWin", fields.firstWin)
		end
		return function()
			DataService.update(plr, function(p: any)
				p.entitlements.paidTier = old.paidTier
				p.boosts.hypeSec = old.hypeSec
				p.firstWin = old.firstWin
			end)
			-- qa does not fire EntitlementsChanged (one writer): rejoin if the HUD multiplier looks stale afterwards
			plr:SetAttribute("FirstWin", oldAttr)
		end
	end

	-- 3c step 1 / 3: lookup-level answers. These run while ids are placeholder 0.
	if processReceipt == nil then
		t.skip("processReceipt lookup tests", "MonetizationService.processReceipt seam missing (QA-F9)")
	else
		local pr: (any) -> any = processReceipt
		t.test("receipt for a player who is not in the server: NotProcessedYet, nothing granted", function()
			for _, userId in { 1, 2 ^ 40, -5 } do
				local ok, res = pcall(pr, {
					PurchaseId = newId("absent"),
					PlayerId = userId,
					ProductId = 0,
					CurrencySpent = 4,
					CurrencyType = Enum.CurrencyType.Robux,
					PlaceIdWherePurchased = game.PlaceId,
				})
				t.ok(ok, `processReceipt(absent {userId}) threw: {res}`)
				t.eq(res, NotYet, `processReceipt(absent {userId})`)
			end
		end)
		t.test("receipt with product id 0 or an unknown id: NotProcessedYet, no receipt recorded", function()
			for _, productId in { 0, 1, 987654321, -1 } do
				local id = newId("unknown")
				local pets = petCount(nil)
				local ok, res = pcall(pr, {
					PurchaseId = id,
					PlayerId = plr.UserId,
					ProductId = productId,
					CurrencySpent = 4,
					CurrencyType = Enum.CurrencyType.Robux,
					PlaceIdWherePurchased = game.PlaceId,
				})
				t.ok(ok, `processReceipt(id {productId}) threw: {res}`)
				t.eq(res, NotYet, `processReceipt(id {productId})`)
				t.eq(receiptCount(id), 0, `id {productId}: receipt recorded`)
				t.eq(petCount(nil), pets, `id {productId}: pets changed`)
			end
		end)
	end

	if grantEntry == nil then
		t.skip(
			"receipt grant tests (dedupe, failures, ladder, restricted)",
			"grantEntry seam missing (QA-F9)"
		)
		return
	end
	local ge: (Player, any, string) -> any = grantEntry
	local E = Catalog.Entries

	t.test("duplicate receipt: granted once, both answers PurchaseGranted, id stored once", function()
		local before = invKeys()
		TestKit.with({
			function()
				cleanupPets(before)
			end,
		}, function()
			local id = newId("dup")
			local n0 = petCount("RingLightRetriever")
			t.eq(ge(plr, E.RingLightRetriever, id), Granted, "first delivery")
			t.eq(petCount("RingLightRetriever"), n0 + 1, "first delivery grants one pet")
			t.eq(ge(plr, E.RingLightRetriever, id), Granted, "second delivery (Roblox retry)")
			t.eq(ge(plr, E.RingLightRetriever, id), Granted, "third delivery")
			t.eq(petCount("RingLightRetriever"), n0 + 1, "retries grant nothing more")
			t.eq(receiptCount(id), 1, "PurchaseId stored once")
			-- a different PurchaseId for the same product is a new purchase
			t.eq(ge(plr, E.RingLightRetriever, newId("dup2")), Granted, "second purchase")
			t.eq(petCount("RingLightRetriever"), n0 + 2, "second purchase grants")
		end)
	end)

	t.test(
		"save failure before PurchaseGranted: NotProcessedYet, and the retry does not grant twice",
		function()
			local captured: ((any) -> boolean)? = nil
			local restore = TestKit.patch(DataService, "saveAndConfirm", function(_p: Player, predicate: any)
				captured = predicate
				return false -- the save never confirmed (outage, or the session ended first)
			end)
			if restore == nil then
				error("could not patch DataService.saveAndConfirm (frozen?)")
			end
			local before = invKeys()
			local id = newId("savefail")
			local n0 = petCount("RingLightRetriever")
			TestKit.with({
				restore,
				function()
					cleanupPets(before)
				end,
			}, function()
				local res = ge(plr, E.RingLightRetriever, id)
				t.ok(
					captured ~= nil,
					"MonetizationService never called DataService.saveAndConfirm through the module table"
				)
				t.eq(res, NotYet, "answer while the save is unconfirmed (3c step 5)")
				local pred: (any) -> boolean = captured :: any
				t.eq(
					pred({ receipts = { "other" } }),
					false,
					"save predicate accepts a save without the PurchaseId"
				)
				t.eq(
					pred({ receipts = { "other", id } }),
					true,
					"save predicate rejects the save holding the id"
				)
				restore()
				-- Roblox retries the same PurchaseId later: the id is already in the profile, so no second grant
				t.eq(ge(plr, E.RingLightRetriever, id), Granted, "retry after the save works")
				t.eq(
					petCount("RingLightRetriever"),
					n0 + 1,
					"granted exactly once across the failure and the retry"
				)
				t.eq(receiptCount(id), 1, "id stored once")
			end)
		end
	)

	if getGrant == nil or type(Monetization.registerGrant) ~= "function" then
		t.skip("grant-failure tests", "getGrant seam missing (QA-F9)")
	else
		local original = getGrant("FixedPet")
		local function swapGrant(fn: any): () -> ()
			local okSwap, err = pcall(Monetization.registerGrant, "FixedPet", fn)
			assert(okSwap, `registerGrant refused a test swap: {err}`)
			return function()
				Monetization.registerGrant("FixedPet", original)
			end
		end
		if original == nil then
			t.skip("grant-failure tests", "no FixedPet grant registered (PetService T-073 not merged)")
		else
			t.test("grant returns false: NotProcessedYet, no receipt recorded, nothing granted", function()
				local id = newId("grantfalse")
				local pets = petCount(nil)
				TestKit.with({ swapGrant(function()
					return false
				end) }, function()
					t.eq(ge(plr, E.RingLightRetriever, id), NotYet, "answer")
					t.eq(receiptCount(id), 0, "receipt recorded after a refused grant")
					t.eq(petCount(nil), pets, "pets changed")
				end)
			end)
			t.test("grant throws: NotProcessedYet (or a thrown callback), no receipt recorded", function()
				local id = newId("grantthrow")
				TestKit.with(
					{ swapGrant(function()
						error("qa: simulated grant error")
					end) },
					function()
						local ok, res = pcall(ge, plr, E.RingLightRetriever, id)
						t.ok((not ok) or res == NotYet, `answer {res}`)
						t.eq(receiptCount(id), 0, "receipt recorded after a grant error")
					end
				)
			end)
			-- QA-F11: DataService.update keeps changes made before an error, so a grant that writes and then fails
			-- leaves a partial grant behind, and Roblox's retry applies it again. MonetizationService must grant on a
			-- copy (or roll back) so a failed grant changes nothing.
			t.test("grant writes then fails: the partial write is rolled back (QA-F11)", function()
				local id = newId("partial")
				local donated0 = data().stats.robuxDonated
				TestKit.with({
					swapGrant(function(_p: Player, _k: string, d: any)
						d.stats.robuxDonated += 1
						return false
					end),
				}, function()
					t.eq(ge(plr, E.RingLightRetriever, id), NotYet, "answer")
					t.eq(data().stats.robuxDonated, donated0, "partial write survived a refused grant")
				end)
				-- the throwing variant
				TestKit.with({
					swapGrant(function(_p: Player, _k: string, d: any)
						d.stats.robuxDonated += 1
						error("qa: grant error after a write")
					end),
				}, function()
					pcall(ge, plr, E.RingLightRetriever, newId("partial2"))
				end)
				local after = data().stats.robuxDonated
				DataService.update(plr, function(p: any)
					p.stats.robuxDonated = donated0
				end)
				t.eq(after, donated0, "partial write survived a grant error")
			end)
		end
	end

	t.test("receipt before FirstWin is still delivered (D-016 #9: the gate is on prompts only)", function()
		local before = invKeys()
		local n0 = petCount("RingLightRetriever")
		TestKit.with({
			setFields({ firstWin = false }),
			function()
				cleanupPets(before)
			end,
		}, function()
			t.eq(ge(plr, E.RingLightRetriever, newId("prefirstwin")), Granted, "answer")
			t.eq(petCount("RingLightRetriever"), n0 + 1, "granted before FirstWin")
		end)
	end)

	-- D-019 #3 through the real PaidTier grant (MultiplierService).
	local function ladderCase(owned: number, key: string, expectTier: number, expectHype: number)
		local start = math.max(0, EconomyConfig and EconomyConfig.BOOST_CAP_SEC - 3600 or 3600)
		TestKit.with({ setFields({ paidTier = owned, hypeSec = start }) }, function()
			t.eq(ge(plr, E[key], newId(`ladder{owned}{key}`)), Granted, `owned {owned} + {key}: answer`)
			local d = data()
			t.eq(d.entitlements.paidTier, expectTier, `owned {owned} + {key}: paidTier`)
			local gained = d.boosts.hypeSec - start
			t.ok(
				gained <= expectHype and gained >= expectHype - HYPE_TOL,
				`owned {owned} + {key}: Hype +{gained}, expected +{expectHype}`
			)
		end)
	end
	t.test("ladder receipt for the next tier climbs one tier, no Hype", function()
		ladderCase(0, "MpX2", 1, 0)
		ladderCase(2, "MpX8", 3, 0)
		ladderCase(4, "MpX32", 5, 0)
	end)
	t.test(
		"ladder receipt for an owned, lower or skip-ahead tier gives Hype only, cap bypassed (D-019 #3)",
		function()
			ladderCase(1, "MpX2", 1, 4 * 300) -- owned
			ladderCase(3, "MpX4", 3, 8 * 300) -- lower
			ladderCase(0, "MpX32", 0, 79 * 300) -- skip ahead from nothing: 6.6 h of Hype, past the 2 h cap
			ladderCase(1, "MpX8", 1, 19 * 300) -- skip ahead by one
			ladderCase(5, "MpX32", 5, 79 * 300) -- max tier re-buy
		end
	)
	t.test("five forced MpX2 receipts end at tier 1 (RC-3 exploit)", function()
		TestKit.with({ setFields({ paidTier = 0 }) }, function()
			for i = 1, 5 do
				ge(plr, E.MpX2, newId(`rc3-{i}`))
			end
			t.eq(data().entitlements.paidTier, 1, "paidTier after 5 x MpX2")
		end)
	end)
	t.test("Hype Snack receipt at the 2 h cap adds the full 10 min, never drops it (D-019 #4)", function()
		local cap = if EconomyConfig then EconomyConfig.BOOST_CAP_SEC else 7200
		TestKit.with({ setFields({ hypeSec = cap - 60 }) }, function()
			t.eq(ge(plr, E.HypeSnack, newId("cap")), Granted, "answer")
			local got = data().boosts.hypeSec
			t.ok(
				got >= cap + 540 - HYPE_TOL and got <= cap + 540,
				`hypeSec {got}, expected about {cap + 540}`
			)
		end)
	end)

	-- GDD 5 / D-016 #4: a restricted player's Robux egg receipt grants the disclosed fixed pet, never a roll.
	t.test("restricted player Robux egg: fixed pet x count, never a roll, pity unchanged", function()
		if Compliance == nil or PetRoll == nil then
			error("ComplianceService or Gameplay/Util/PetRoll missing")
		end
		local rolls = 0
		local realPick = PetRoll.pick
		local restores = {
			TestKit.patch(Compliance, "paidRandomAllowed", function()
				return false
			end),
			TestKit.patch(PetRoll, "pick", function(...)
				rolls += 1
				return realPick(...)
			end),
		}
		assert(restores[1] and restores[2], "could not patch ComplianceService / PetRoll (frozen?)")
		local oldAttr = plr:GetAttribute("PaidRandomAllowed")
		plr:SetAttribute("PaidRandomAllowed", false)
		table.insert(restores, function()
			plr:SetAttribute("PaidRandomAllowed", oldAttr)
		end)
		local before = invKeys()
		table.insert(restores, function()
			cleanupPets(before)
		end)
		TestKit.with(restores, function()
			for _, key in { "StarEgg1", "StarEgg3", "GalaxyEgg1", "GalaxyEgg3" } do
				local g = Catalog.restrictedGrant(key)
				local e = E[key]
				for round = 1, 5 do
					local pity0 = data().pity[e.eggId] or 0
					local total0 = petCount(nil)
					local fixed0 = petCount(g.petId)
					t.eq(ge(plr, e, newId(`restricted-{key}-{round}`)), Granted, `{key} answer`)
					t.eq(petCount(nil), total0 + g.count, `{key}: {g.count} pets added`)
					t.eq(petCount(g.petId), fixed0 + g.count, `{key}: all {g.count} are {g.petId}`)
					t.eq(data().pity[e.eggId] or 0, pity0, `{key}: pity counter changed`)
				end
			end
			t.eq(rolls, 0, "PetRoll.pick was called for a restricted player")
		end)
	end)

	t.test("allowed player Robux egg: rolls from that egg only, count pets, pity moves", function()
		if Compliance == nil or EconomyConfig == nil then
			error("ComplianceService or EconomyConfig missing")
		end
		local restores = {
			TestKit.patch(Compliance, "paidRandomAllowed", function()
				return true
			end),
		}
		assert(restores[1], "could not patch ComplianceService")
		local before = invKeys()
		table.insert(restores, function()
			cleanupPets(before)
		end)
		TestKit.with(restores, function()
			local pool = {}
			for _, p in EconomyConfig.EGGS.StarEgg.pets do
				pool[p.petId] = true
			end
			local keys0 = invKeys()
			t.eq(ge(plr, E.StarEgg3, newId("allowed")), Granted, "answer")
			local added = 0
			for uid, p in data().pets.inventory do
				if not keys0[tostring(uid)] then
					added += 1
					t.ok(pool[p.id], `StarEgg3 granted {p.id}, not a Star Egg pet`)
				end
			end
			t.eq(added, 3, "StarEgg3 adds 3 pets")
		end)
	end)

	t.test("no receipt changes coins, tools, pods, rebirths or World 2 (GDD 8g, live profile)", function()
		local d = data()
		local snap = {
			coins = d.coins,
			toolIndex = d.toolIndex,
			podsMask = d.podsMask,
			rebirths = d.rebirths,
			world2 = d.world2Unlocked,
			earned = d.stats.totalCoinsEarned,
		}
		local before = invKeys()
		TestKit.with({
			setFields({ paidTier = 0, hypeSec = 0 }),
			function()
				cleanupPets(before)
			end,
		}, function()
			for _, key in Catalog.OnSaleKeys do
				-- permanent entitlements are left alone (no rollback path for VIP / fits on a test account)
				if E[key].grantKind ~= "Entitlement" then
					ge(plr, E[key], newId(`fw-{key}`))
				end
			end
			d = data()
			t.eq(d.coins, snap.coins, "coins")
			t.eq(d.toolIndex, snap.toolIndex, "toolIndex")
			t.eq(d.podsMask, snap.podsMask, "podsMask")
			t.eq(d.rebirths, snap.rebirths, "rebirths")
			t.eq(d.world2Unlocked, snap.world2, "world2Unlocked")
			t.eq(d.stats.totalCoinsEarned, snap.earned, "totalCoinsEarned")
		end)
	end)
end
