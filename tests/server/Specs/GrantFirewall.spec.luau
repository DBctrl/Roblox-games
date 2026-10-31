--!strict
-- T-081: GDD 8g coin firewall, dynamic half. Walks the registered grant fn of every one of the 23 products (both
-- policy states for Robux eggs) on a COPY of the profile and fails if a grant touches coins, coin-shop items
-- (toolIndex, podsMask), rebirths or World 2, writes outside what architecture 4e says it writes, yields, or calls
-- DataService.addCoins / trySpendCoins / update or a coin-egg hatch. Owned by qa.
-- Static half: `python3 -I tests/static/check_grants.py` (every registerGrant body, no Studio needed).
--
-- Needs a real Player (Play, F5): grant fns take the Player (PetService reads its policy flag). The live profile is
-- never handed to a grant here, only a deep copy, so the account is not changed. Reaches the registry through the
-- `MonetizationService.getGrant(kind)` seam (QA-F9); SKIPs without it.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local TestKit = require(ReplicatedStorage:WaitForChild("QaTests"):WaitForChild("TestKit"))

-- Never written by any grant (architecture 4e "No grant may touch ...", GDD 8g, D-021).
local FORBIDDEN =
	{ "coins", "toolIndex", "podsMask", "rebirths", "world2Unlocked", "mp", "lifetimeMp", "daily", "codes" }

-- Paths each grant kind may change (architecture 4e "What the grant writes"). Depth 2: "top" or "top.child".
local ALLOWED: { [string]: { string } } = {
	PaidTier = { "entitlements.paidTier", "boosts.hypeSec" },
	Boost = { "boosts.hypeSec", "boosts.speedSec" },
	Entitlement = { "entitlements.autoClicker", "entitlements.vip", "entitlements.cosmetics" },
	FixedPet = { "pets.inventory", "pets.nextUid" },
	StarterPack = {
		"pets.inventory",
		"pets.nextUid",
		"boosts.hypeSec",
		"entitlements.cosmetics",
		"entitlements.starterPack",
	},
	RobuxEgg = { "pets.inventory", "pets.nextUid", "pity" },
	Donation = { "stats.robuxDonated" },
}

-- Changed paths between two profiles, depth 2 ("pets.inventory", "coins").
local function changedPaths(a: any, b: any): { string }
	local out = {}
	local seen = {}
	local function visitTop(k: any)
		if seen[k] then
			return
		end
		seen[k] = true
		local va, vb = a[k], b[k]
		if type(va) == "table" and type(vb) == "table" then
			local inner = {}
			for k2 in va do
				inner[k2] = true
			end
			for k2 in vb do
				inner[k2] = true
			end
			for k2 in inner do
				if TestKit.diff(va[k2], vb[k2]) ~= nil then
					table.insert(out, `{tostring(k)}.{tostring(k2)}`)
				end
			end
		elseif TestKit.diff(va, vb) ~= nil then
			table.insert(out, tostring(k))
		end
	end
	for k in a do
		visitTop(k)
	end
	for k in b do
		visitTop(k)
	end
	table.sort(out)
	return out
end

local function allowed(kind: string, path: string): boolean
	if string.sub(path, 1, 11) == "milestones." or path == "milestones" then
		return true -- funnel dedupe (TelemetryService), harmless
	end
	for _, p in ALLOWED[kind] or {} do
		if path == p or string.sub(path, 1, #p + 1) == p .. "." then
			return true
		end
	end
	return false
end

return function(t: TestKit.Suite)
	local Server = ServerScriptService:FindFirstChild("Server")
	local Shared = ReplicatedStorage:FindFirstChild("Shared")
	local DataService = TestKit.tryRequire(Server, { "Data", "DataService" }) :: any
	local Monetization = TestKit.tryRequire(Server, { "Data", "MonetizationService" }) :: any
	local Compliance = TestKit.tryRequire(Server, { "Data", "ComplianceService" }) :: any
	local PetService = TestKit.tryRequire(Server, { "Gameplay", "PetService" }) :: any
	local ProfileSchema = TestKit.tryRequire(Server, { "Data", "Util", "ProfileSchema" }) :: any
	local Catalog = TestKit.tryRequire(Shared, { "Contracts", "ProductCatalog" }) :: any
	local Types = TestKit.tryRequire(Shared, { "Contracts", "Types" }) :: any

	if Monetization == nil or DataService == nil or Catalog == nil or ProfileSchema == nil then
		t.skip(
			"grant firewall",
			"MonetizationService (T-056), DataService, ProfileSchema or ProductCatalog missing"
		)
		return
	end
	local getGrant = TestKit.firstFn(Monetization, { "getGrant", "_getGrant" })
	if getGrant == nil then
		t.skip("grant firewall", "MonetizationService.getGrant seam missing (QA-F9); static half still runs")
		return
	end
	local players = TestKit.loadedPlayers(1)
	if #players == 0 then
		t.skip("grant firewall", "no Player with DataLoaded (use Play, not Run)")
		return
	end
	local plr: Player = players[1]

	-- A copy of the live profile with every coin-side field set to an odd value, so a write is visible.
	local function testCopy(): any
		local live = DataService.getData(plr)
		assert(live, "getData nil")
		local d = ProfileSchema.deepCopy(live)
		d.coins = 12345
		d.toolIndex = 3
		d.podsMask = 0b101
		d.rebirths = 1
		d.world2Unlocked = false
		d.entitlements.paidTier = 0
		d.entitlements.vip = false
		d.entitlements.autoClicker = false
		d.entitlements.starterPack = false
		d.boosts.hypeSec = 0
		return d
	end

	-- Counts calls to anything a grant must never call while it runs.
	local forbiddenCalls: { string } = {}
	local function trap(mod: any, name: string): (() -> ())?
		if mod == nil or type(mod[name]) ~= "function" then
			return nil
		end
		local real = mod[name]
		return TestKit.patch(mod, name, function(...)
			table.insert(forbiddenCalls, name)
			return real(...)
		end)
	end

	local keys: { string } = if Types and Types.ProductKeys then Types.ProductKeys else {}
	if #keys == 0 then
		for k in Catalog.Entries do
			table.insert(keys, k)
		end
	end

	for _, key in keys do
		local entry = Catalog.Entries[key]
		local kind = entry and entry.grantKind
		local fn = kind and getGrant(kind)
		if fn == nil then
			t.skip(`firewall {key}`, `no grant registered for {tostring(kind)}`)
			continue
		end
		local policies = if kind == "RobuxEgg" then { true, false } else { true }
		for _, allowRandom in policies do
			local suffix = if kind ~= "RobuxEgg"
				then ""
				elseif allowRandom then " (allowed)"
				else " (restricted)"
			local label = `firewall {key}{suffix}`
			t.test(label, function()
				local restores = {
					Compliance and TestKit.patch(Compliance, "paidRandomAllowed", function()
						return allowRandom
					end),
					trap(DataService, "addCoins"),
					trap(DataService, "trySpendCoins"),
					trap(DataService, "update"),
					trap(PetService, "tryHatch"),
				}
				local live = DataService.getData(plr)
				local liveCoins = live and live.coins
				local before = testCopy()
				local copy = ProfileSchema.deepCopy(before)
				table.clear(forbiddenCalls)
				local thread = coroutine.create(fn)
				local ok, res
				TestKit.with(restores, function()
					ok, res = coroutine.resume(thread, plr, key, copy)
				end)
				local finished = coroutine.status(thread) == "dead"
				if not finished then
					coroutine.close(thread)
				end
				t.ok(finished, `{key}: grant yielded (must be synchronous, architecture 1b)`)
				t.ok(ok, `{key}: grant threw: {res}`)
				t.eq(#forbiddenCalls, 0, `{key}: grant called {table.concat(forbiddenCalls, ", ")}`)
				local after = DataService.getData(plr)
				t.eq(after and after.coins, liveCoins, `{key}: live coins changed`)
				for _, f in FORBIDDEN do
					t.ok(TestKit.diff(copy[f], before[f]) == nil, `{key}: grant wrote {f}`)
				end
				for _, path in changedPaths(before, copy) do
					t.ok(allowed(kind, path), `{key} ({kind}): grant wrote {path}, outside architecture 4e`)
				end
				if not entry.onSale then
					-- D-038: out-of-scope products are never granted; a grant that still works is a lead, not a fail,
					-- because byProductId can never return them. Record it in the label only.
					return
				end
				if res == true then
					t.ok(#changedPaths(before, copy) > 0, `{key}: grant returned true but changed nothing`)
				end
				if kind == "RobuxEgg" and res == true then
					local added = TestKit.count(copy.pets.inventory) - TestKit.count(before.pets.inventory)
					t.eq(added, entry.count, `{key}: pets added`)
					if not allowRandom then
						local g = Catalog.restrictedGrant(key)
						for uid, p in copy.pets.inventory do
							if before.pets.inventory[uid] == nil then
								t.eq(p.id, g.petId, `{key} restricted: pet {uid}`)
							end
						end
						t.ok(TestKit.diff(copy.pity, before.pity) == nil, `{key} restricted: pity changed`)
					end
				end
			end)
		end
	end
end
