--!strict
-- T-081: ProductCatalog pure functions (canSell, ladderGrant, restrictedGrant, byProductId) and the catalog-level
-- coin firewall. Owned by qa. Written against docs/architecture.md v1.3 section 4f, D-019 #3, D-038 and GDD 5/8.
-- Pure: needs no Player, runs in Studio Run mode (F8).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local TestKit = require(ReplicatedStorage:WaitForChild("QaTests"):WaitForChild("TestKit"))

-- D-038 approved prices (R$). Anything else on sale, or a different price, fails (gate 5).
local APPROVED: { [string]: number } = {
	MpX2 = 4,
	MpX4 = 8,
	MpX8 = 19,
	MpX16 = 39,
	MpX32 = 79,
	HypeSnack = 2,
	StarterPack = 9,
	RingLightRetriever = 29,
	AutoClicker = 39,
	Vip = 99,
	GoldenGlowFit = 249,
	StarEgg1 = 25,
	StarEgg3 = 69,
	GalaxyEgg1 = 49,
	GalaxyEgg3 = 129,
}
local NOT_ON_SALE =
	{ "SpeedSneakers", "NeonPup", "NeonIconFit", "Tip5", "Tip25", "Tip100", "Tip500", "Tip1000" }
local LADDER = { "MpX2", "MpX4", "MpX8", "MpX16", "MpX32" }
local COIN_WORDS = { "coin", "Coin", "COIN", "rebirth", "Rebirth", "pod", "Pod", "tool", "Tool" }

return function(t: TestKit.Suite)
	local Shared = ReplicatedStorage:FindFirstChild("Shared")
	local Catalog = TestKit.tryRequire(Shared, { "Contracts", "ProductCatalog" }) :: any
	local EconomyConfig = TestKit.tryRequire(Shared, { "Gameplay", "EconomyConfig" }) :: any
	if Catalog == nil then
		t.skip("all ProductCatalog tests", "Contracts/ProductCatalog (T-069) not merged")
		return
	end

	t.test("23 entries, 15 on sale at the D-038 prices, 8 not on sale", function()
		t.eq(TestKit.count(Catalog.Entries), 23, "entry count")
		t.eq(#Catalog.OnSaleKeys, 15, "on-sale count")
		for _, key in Catalog.OnSaleKeys do
			local e = Catalog.get(key)
			t.ok(e and e.onSale, `{key} on sale`)
			t.eq(e.priceRobux, APPROVED[key], `{key} price`)
			t.eq(e.priceLabel, `{APPROVED[key]} R$`, `{key} label`)
		end
		for key, price in APPROVED do
			t.ok(table.find(Catalog.OnSaleKeys, key) ~= nil, `{key} ({price} R$) missing from OnSaleKeys`)
		end
		for _, key in NOT_ON_SALE do
			local e = Catalog.get(key)
			t.ok(e ~= nil, `{key} entry exists`)
			t.eq(e.onSale, false, `{key} onSale`)
			t.eq(e.priceRobux, 0, `{key} price`)
			t.eq(e.productId, 0, `{key} productId`)
		end
	end)

	t.test("canSell: unknown, not-on-sale and placeholder-id keys are refused", function()
		local junk: { any } =
			{ "", "mpx2", "MpX64", "Coins", "CoinPouch", "SkipRebirth", string.rep("A", 5000) }
		for _, k in junk do
			local ok, why = Catalog.canSell(k)
			t.eq(ok, false, `canSell({string.sub(tostring(k), 1, 20)})`)
			t.eq(why, "UnknownKey", `canSell({string.sub(tostring(k), 1, 20)}) reason`)
		end
		-- Non-string input from a client must not throw either (the handler type-checks first, this is defence).
		for _, k in { 5, true, {}, 0 / 0 } :: { any } do
			local ok, res = pcall(Catalog.canSell, k)
			t.ok(ok and res == false, `canSell({typeof(k)}) refused without error`)
		end
		for _, key in NOT_ON_SALE do
			local ok, why = Catalog.canSell(key)
			t.eq(ok, false, `canSell({key})`)
			t.eq(why, "NotOnSale", `canSell({key}) reason`)
		end
		for _, key in Catalog.OnSaleKeys do
			local e = Catalog.get(key)
			local ok, why = Catalog.canSell(key)
			if e.productId == 0 then
				t.eq(ok, false, `canSell({key}) with id 0`)
				t.eq(why, "NoProductId", `canSell({key}) reason`)
			else
				t.eq(ok, true, `canSell({key}) with id {e.productId}`)
			end
		end
	end)

	t.test("byProductId: 0, negatives, NaN and unknown ids are nil; filled ids round-trip", function()
		for _, id in { 0, -1, 0 / 0, math.huge, 1, 123456789 } :: { any } do
			t.eq(Catalog.byProductId(id), nil, `byProductId({id})`)
		end
		for key, e in Catalog.Entries do
			if e.productId ~= 0 then
				t.eq(Catalog.byProductId(e.productId), e, `byProductId({key})`)
			end
		end
		for _, key in Catalog.missingIds() do
			t.ok(Catalog.get(key).onSale, `missingIds lists only on-sale keys ({key})`)
		end
	end)

	t.test("ladder: tiers 1..5, multipliers match EconomyConfig.PAID_TIER_MULTS, next tier only", function()
		for tier, key in LADDER do
			local e = Catalog.get(key)
			t.eq(Catalog.ladderKey(tier), key, `ladderKey({tier})`)
			t.eq(e.tier, tier, `{key}.tier`)
			t.eq(e.grantKind, "PaidTier", `{key}.grantKind`)
			t.eq(e.nextTierOnly, true, `{key}.nextTierOnly`)
			t.eq(e.repeatable, false, `{key}.repeatable`)
			if EconomyConfig then
				t.eq(e.multiplier, EconomyConfig.PAID_TIER_MULTS[tier + 1], `{key}.multiplier`)
			end
		end
		t.eq(Catalog.ladderKey(0), nil, "ladderKey(0)")
		t.eq(Catalog.ladderKey(6), nil, "ladderKey(6)")
		t.eq(Catalog.HYPE_FALLBACK_SEC_PER_ROBUX * 2, 600, "fallback rate is 10 min per 2 R$")
	end)

	-- D-019 #3: every (key, owned tier) pair. Only key.tier == owned + 1 climbs; everything else is Hype time.
	t.test("ladderGrant D-019 matrix: next tier climbs, owned/lower/skip-ahead give Hype only", function()
		for _, key in LADDER do
			local e = Catalog.get(key)
			for owned = 0, 5 do
				local g = Catalog.ladderGrant(key, owned)
				local label = `ladderGrant({key}, owned {owned})`
				if e.tier == owned + 1 then
					t.eq(g.tier, e.tier, `{label}.tier`)
					t.eq(g.hypeSec, 0, `{label}.hypeSec`)
				else
					t.eq(g.tier, nil, `{label}.tier (never the next tier)`)
					t.eq(g.hypeSec, e.priceRobux * 300, `{label}.hypeSec`)
				end
			end
		end
	end)

	t.test("ladderGrant D-019 named cases", function()
		-- re-buy of an owned tier
		local g = Catalog.ladderGrant("MpX2", 1)
		t.eq(g.tier, nil, "owned x2 + MpX2: no tier")
		t.eq(g.hypeSec, 1200, "owned x2 + MpX2: 20 min Hype (4 R$)")
		-- lower tier
		g = Catalog.ladderGrant("MpX4", 4)
		t.eq(g.tier, nil, "owned x16 + MpX4: no tier")
		t.eq(g.hypeSec, 2400, "owned x16 + MpX4: 40 min Hype (8 R$)")
		-- skip-ahead (a client-forced prompt for x32 at tier 0)
		g = Catalog.ladderGrant("MpX32", 0)
		t.eq(g.tier, nil, "tier 0 + MpX32: no tier")
		t.eq(g.hypeSec, 79 * 300, "tier 0 + MpX32: 79 R$ of Hype")
		g = Catalog.ladderGrant("MpX8", 1)
		t.eq(g.tier, nil, "tier 1 + MpX8 (skips x4): no tier")
		-- max tier re-buy
		g = Catalog.ladderGrant("MpX32", 5)
		t.eq(g.tier, nil, "tier 5 + MpX32: no tier")
		t.eq(g.hypeSec, 79 * 300, "tier 5 + MpX32 Hype")
		-- the RC-3 exploit: 5 forced 4 R$ receipts must not climb past x2
		local tier = 0
		local hype = 0
		for _ = 1, 5 do
			local r = Catalog.ladderGrant("MpX2", tier)
			tier = r.tier or tier
			hype += r.hypeSec
		end
		t.eq(tier, 1, "5 x MpX2 receipts end at tier 1")
		t.eq(hype, 4 * 1200, "the 4 repeat receipts give Hype")
		-- the honest climb
		tier = 0
		for _, key in LADDER do
			tier = Catalog.ladderGrant(key, tier).tier or -1
		end
		t.eq(tier, 5, "buying x2..x32 in order reaches tier 5")
	end)

	t.test("ladderGrant with a corrupt owned tier never climbs", function()
		for _, owned in { -1, 6, 99, 0.5, 1.5, 0 / 0, math.huge, -math.huge } :: { number } do
			for _, key in LADDER do
				local ok, g = pcall(Catalog.ladderGrant, key, owned)
				t.ok(ok, `ladderGrant({key}, {owned}) threw: {g}`)
				local e = Catalog.get(key)
				if g.tier ~= nil then
					t.eq(g.tier, e.tier, `ladderGrant({key}, {owned}).tier`)
					t.ok(owned + 1 == e.tier, `ladderGrant({key}, {owned}) climbed from a corrupt tier`)
				end
				t.ok(g.hypeSec == g.hypeSec and g.hypeSec >= 0 and g.hypeSec < math.huge, `{key} hype finite`)
			end
		end
	end)

	t.test("ladderGrant and restrictedGrant refuse the wrong kind of key", function()
		for _, key in { "HypeSnack", "Vip", "StarEgg1", "Coins", "" } do
			t.fails(function()
				Catalog.ladderGrant(key, 0)
			end, `ladderGrant({key})`)
		end
		for _, key in { "MpX2", "RingLightRetriever", "StarterPack", "BasicEgg", "" } do
			t.fails(function()
				Catalog.restrictedGrant(key)
			end, `restrictedGrant({key})`)
		end
	end)

	t.test("restrictedGrant: fixed pet and count per Robux egg, matching EconomyConfig", function()
		local expect = {
			StarEgg1 = { "StarlightCorgi", 1, "StarEgg" },
			StarEgg3 = { "StarlightCorgi", 3, "StarEgg" },
			GalaxyEgg1 = { "NebulaFox", 1, "GalaxyEgg" },
			GalaxyEgg3 = { "NebulaFox", 3, "GalaxyEgg" },
		}
		local robuxEggs = 0
		for key, e in Catalog.Entries do
			if e.grantKind == "RobuxEgg" then
				robuxEggs += 1
				t.ok(expect[key] ~= nil, `unexpected Robux egg product {key}`)
			end
		end
		t.eq(robuxEggs, 4, "Robux egg products")
		for key, x in expect do
			local g = Catalog.restrictedGrant(key)
			t.eq(g.petId, x[1], `{key} restricted pet`)
			t.eq(g.count, x[2], `{key} restricted count`)
			local e = Catalog.get(key)
			t.eq(e.eggId, x[3], `{key}.eggId`)
			t.eq(e.count, x[2], `{key}.count`)
			-- the same call twice is the same answer (deterministic, no roll)
			local g2 = Catalog.restrictedGrant(key)
			t.ok(g2.petId == g.petId and g2.count == g.count, `{key} deterministic`)
			-- the disclosure text names the pet (legal RC-4)
			local petWord = if x[1] == "StarlightCorgi" then "Starlight Corgi" else "Nebula Fox"
			t.ok(string.find(e.description, petWord, 1, true) ~= nil, `{key} description names {petWord}`)
			if EconomyConfig then
				local egg = EconomyConfig.EGGS[x[3]]
				t.ok(egg ~= nil, `EconomyConfig.EGGS.{x[3]}`)
				t.eq(egg.restrictedGrant, g.petId, `{key} matches EGGS.{x[3]}.restrictedGrant`)
				t.eq(egg.currency, "Robux", `EGGS.{x[3]} is a Robux egg`)
				local inEgg = false
				for _, p in egg.pets do
					inEgg = inEgg or p.petId == g.petId
				end
				t.ok(inEgg, `{g.petId} is one of the {x[3]} pets`)
			end
		end
	end)

	-- GDD 8g / D-021: nothing in the catalog may grant coins, coin-shop items, rebirths, pods or a coin egg.
	t.test("catalog coin firewall: no coin product, no coin-egg grant, no coin field", function()
		local allowedKinds = {
			PaidTier = true,
			Boost = true,
			Entitlement = true,
			FixedPet = true,
			StarterPack = true,
			RobuxEgg = true,
		}
		allowedKinds.Donation = true
		for key, e in Catalog.Entries do
			t.ok(allowedKinds[e.grantKind], `{key} grantKind {e.grantKind}`)
			for field in e do
				local f = tostring(field)
				for _, w in COIN_WORDS do
					t.ok(string.find(f, w, 1, true) == nil, `{key} has field {f}`)
				end
			end
			for _, w in { "coin", "Coin" } do
				t.ok(string.find(e.displayName, w, 1, true) == nil, `{key} name mentions {w}`)
				t.ok(string.find(e.description, w, 1, true) == nil, `{key} description mentions {w}`)
			end
			if e.eggId ~= nil and EconomyConfig then
				t.eq(EconomyConfig.EGGS[e.eggId].currency, "Robux", `{key} egg {e.eggId} is not a coin egg`)
			end
			if e.petId ~= nil and EconomyConfig then
				for eggId, egg in EconomyConfig.EGGS do
					if egg.currency ~= "Robux" then
						for _, p in egg.pets do
							t.ok(p.petId ~= e.petId, `{key} grants {e.petId}, a {eggId} (coin egg) pet`)
						end
					end
				end
			end
		end
		t.eq(Catalog.Entries.StarterPack.eggId, nil, "Starter Pack has no egg (legal 2.6)")
		t.eq(Catalog.Entries.HypeSnack.hypeSec, 600, "Hype Snack 10 min")
		if EconomyConfig then
			t.eq(
				Catalog.Entries.HypeSnack.hypeSec,
				EconomyConfig.HYPE_SNACK_SEC,
				"HypeSnack matches HYPE_SNACK_SEC"
			)
		end
	end)

	t.test("catalog is frozen (no runtime edits of prices or ids)", function()
		t.ok(table.isfrozen(Catalog), "module frozen")
		t.ok(table.isfrozen(Catalog.Entries), "Entries frozen")
		t.ok(table.isfrozen(Catalog.Entries.MpX2), "entry frozen")
		t.fails(function()
			(Catalog.Entries.MpX2 :: any).priceRobux = 1
		end, "price write")
	end)
end
