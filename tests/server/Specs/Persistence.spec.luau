--!strict
-- T-046: persistence. Profile schema round-trip, receipt-id dedupe, rejoin, server hop, DataStore failures.
-- Owned by qa. Written against docs/architecture.md v1.2 section 3 (3a schema, 3c dedupe) and the documented test
-- seams in Data/Util (ProfileSchema is pure; LockedStore.new takes a fake store and injectable now/wait).
-- Pure: needs no Player and no real DataStore, so it runs in Studio Run mode (F8).
--
-- The fake store keeps every record as a JSON string, as a DataStore does, so anything that would not survive a
-- real save (functions, Instances, mixed tables, cycles) fails here first.
-- When ProfileStore replaces the LockedStore fallback (D-028), the LockedStore tests still cover the fallback path;
-- the ProfileStore path needs a Studio Play rejoin (docs/qa playtest script).

local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local TestKit = require(ReplicatedStorage:WaitForChild("QaTests"):WaitForChild("TestKit"))

local KEY = "Player_46"
local USER_ID = 46

type FakeStore = {
	values: { [string]: string },
	fail: boolean,
	writes: number,
	UpdateAsync: (self: FakeStore, key: string, transform: (old: any, keyInfo: any) -> ...any) -> any,
}

local function jsonStore(): FakeStore
	local store: any = { values = {}, fail = false, writes = 0 }
	function store.UpdateAsync(
		self: FakeStore,
		key: string,
		transform: (old: any, keyInfo: any) -> ...any
	): any
		if self.fail then
			error("simulated DataStore outage (qa)")
		end
		local raw = self.values[key]
		local old = if raw ~= nil then HttpService:JSONDecode(raw) else nil
		local new = transform(old, nil)
		if new ~= nil then
			self.values[key] = HttpService:JSONEncode(new)
			self.writes += 1
		end
		return new
	end
	return store :: FakeStore
end

local function never(): boolean
	return false
end

-- A filled-in profile: every field off its default, pets and receipts present, string uids (architecture 3a).
local function populated(template: any): any
	local d = template
	d.coins = 12345
	d.mp = 678.5
	d.lifetimeMp = 99999
	d.rebirths = 2
	d.toolIndex = 5
	d.podsMask = 0b10011
	d.world2Unlocked = false
	d.firstWin = true
	d.rank = 4
	d.quest = { step = 6, done = false }
	d.pets = {
		inventory = { ["1"] = { id = "PuffPup" }, ["2"] = { id = "MirrorFox" }, ["7"] = { id = "SpaPanda" } },
		equipped = { "2", "7" },
		nextUid = 8,
	}
	d.pity = { StarEgg = 4, GalaxyEgg = 9 }
	d.entitlements.paidTier = 2
	d.entitlements.vip = true
	d.entitlements.cosmetics = { RookieShades = true }
	d.boosts = { hypeSec = 600, coinSec = 0, speedSec = 30 }
	d.daily = { streak = 3, lastClaimDay = 20757 }
	d.codes = { LAUNCH = true }
	d.duel = { weekId = 2965, weekWins = 4, rewardLog = { { t = 1793000000, opp = 123 } } }
	d.settings.autoDeleteCommons = true
	d.settings.duelRequests = false
	d.stats.firstJoinUnix = 1793000000
	d.stats.bossWins = 321
	d.milestones = { FirstWin = true, FirstEgg = true }
	d.receipts = { "purchase-a", "purchase-b" }
	return d
end

return function(t: TestKit.Suite)
	local Server = ServerScriptService:FindFirstChild("Server")
	local ProfileSchema = TestKit.tryRequire(Server, { "Data", "Util", "ProfileSchema" }) :: any
	local LockedStore = TestKit.tryRequire(Server, { "Data", "Util", "LockedStore" }) :: any
	if ProfileSchema == nil then
		t.skip("all persistence checks", "Server.Data.Util.ProfileSchema not found (T-012 not merged)")
		return
	end
	local S = ProfileSchema

	-- Schema ------------------------------------------------------------------------------------------------

	t.test("template() is v1 and a fresh copy every call", function()
		local a, b = S.template(), S.template()
		t.eq(a.schemaVersion, S.SCHEMA_VERSION, "template schemaVersion")
		t.eq(S.SCHEMA_VERSION, 1, "SCHEMA_VERSION (architecture 3a)")
		a.pets.equipped[1] = "x"
		a.settings.autoTap = false
		table.insert(a.receipts, "r")
		t.deepEq(b, S.template(), "second template after mutating the first")
	end)

	t.test("template() has every architecture 3a field with its default", function()
		local d = S.template()
		local expected = {
			coins = 0,
			mp = 0,
			lifetimeMp = 0,
			rebirths = 0,
			toolIndex = 1,
			podsMask = 0,
			world2Unlocked = false,
			firstWin = false,
			rank = 1,
		}
		for k, v in expected do
			t.eq(d[k], v, `template.{k}`)
		end
		t.deepEq(d.quest, { step = 1, done = false }, "template.quest")
		t.deepEq(d.pets, { inventory = {}, equipped = {}, nextUid = 1 }, "template.pets")
		t.deepEq(d.settings, {
			duelRequests = true,
			showOwnLook = true,
			autoDeleteCommons = false,
			hideFromDonorBoard = false,
			autoTap = true,
			autoMog = true,
		}, "template.settings")
		for _, k in { "pity", "codes", "milestones", "receipts" } do
			t.deepEq(d[k], {}, `template.{k}`)
		end
		for _, k in { "entitlements", "boosts", "daily", "duel", "stats" } do
			t.eq(type(d[k]), "table", `template.{k}`)
		end
	end)

	t.test("template and a populated profile survive a JSON round-trip + migrate + reconcile", function()
		for label, data in { template = S.template(), populated = populated(S.template()) } do
			local copy = HttpService:JSONDecode(HttpService:JSONEncode(data))
			t.eq(S.migrate(copy), true, `{label}: migrate`)
			S.reconcile(copy)
			t.deepEq(copy, data, `{label} after round-trip`)
		end
	end)

	t.test(
		"reconcile fills missing fields (top level and nested) and never overwrites saved values",
		function()
			local old =
				{ coins = 50, rank = 3, settings = { autoTap = false }, pets = { equipped = { "4" } } }
			S.reconcile(old)
			t.eq(old.coins, 50, "coins kept")
			t.eq(old.rank, 3, "rank kept")
			t.eq(old.settings.autoTap, false, "settings.autoTap kept")
			t.eq(old.settings.autoMog, true, "settings.autoMog filled")
			t.deepEq(old.pets.equipped, { "4" }, "pets.equipped kept")
			t.deepEq(old.pets.inventory, {}, "pets.inventory filled")
			t.eq(old.pets.nextUid, 1, "pets.nextUid filled")
			t.deepEq(old.receipts, {}, "receipts filled")
			t.eq(old.toolIndex, 1, "toolIndex filled")
		end
	)

	t.test("reconcile is idempotent on a full profile", function()
		local d = populated(S.template())
		local before = S.deepCopy(d)
		S.reconcile(d)
		S.reconcile(d)
		t.deepEq(d, before, "populated profile after reconcile x2")
	end)

	t.test("migrate: unversioned save -> v1; newer schema refused (must not be loaded or saved)", function()
		local legacy: any = { coins = 1 }
		t.eq(S.migrate(legacy), true, "migrate unversioned")
		t.eq(legacy.schemaVersion, 1, "schemaVersion set")
		local corrupt: any = { schemaVersion = 0 / 0 }
		t.eq(S.migrate(corrupt), true, "migrate NaN version")
		t.eq(corrupt.schemaVersion, 1, "NaN version repaired")
		t.eq(S.migrate({ schemaVersion = S.SCHEMA_VERSION + 1 }), false, "migrate newer")
	end)

	t.test("migrate does not throw on a corrupt version below 1 (0, -1, 0.5): treat as v1 (QA-11)", function()
		for _, v in { 0, -1, 0.5 } do
			local d: any = { schemaVersion = v }
			local ok, result = pcall(S.migrate, d)
			t.ok(ok, `migrate(schemaVersion = {v}) threw: {tostring(result)}`)
			t.eq(result, true, `migrate(schemaVersion = {v})`)
			t.eq(d.schemaVersion, 1, `schemaVersion after migrate from {v}`)
		end
	end)

	t.test("deepCopy is independent of its source", function()
		local d = populated(S.template())
		local c = S.deepCopy(d)
		t.deepEq(c, d, "copy equals source")
		c.pets.inventory["1"].id = "Changed"
		table.insert(c.receipts, "x")
		t.eq(d.pets.inventory["1"].id, "PuffPup", "source pet unchanged")
		t.eq(#d.receipts, 2, "source receipts unchanged")
	end)

	-- Receipt-id dedupe (3c) --------------------------------------------------------------------------------

	t.test("addReceipt/hasReceipt: dedupe, FIFO trim to 100", function()
		t.eq(S.RECEIPT_LIMIT, 100, "RECEIPT_LIMIT")
		local d = S.template()
		t.eq(S.hasReceipt(d, "p1"), false, "empty list")
		S.addReceipt(d, "p1")
		S.addReceipt(d, "p1")
		t.eq(#d.receipts, 1, "same id twice is stored once")
		t.eq(S.hasReceipt(d, "p1"), true, "hasReceipt p1")
		for i = 2, 105 do
			S.addReceipt(d, `p{i}`)
		end
		t.eq(#d.receipts, 100, "trimmed to 100")
		t.eq(d.receipts[1], "p6", "oldest five dropped first")
		t.eq(d.receipts[100], "p105", "newest last")
		t.eq(S.hasReceipt(d, "p5"), false, "dropped id")
		S.addReceipt(d, "p50")
		t.eq(#d.receipts, 100, "re-adding a kept id changes nothing")
		t.eq(d.receipts[100], "p105", "re-add does not move the id")
	end)

	-- ProcessReceipt steps 2 and 4 modelled on the helpers: grant + record in one mutation, skip if recorded.
	local function processReceipt(data: any, purchaseId: string, grant: (data: any) -> boolean): string
		if S.hasReceipt(data, purchaseId) then
			return "PurchaseGranted"
		end
		if not grant(data) then
			return "NotYetProcessed"
		end
		S.addReceipt(data, purchaseId)
		return "PurchaseGranted"
	end

	t.test(
		"duplicate ProcessReceipt for one PurchaseId grants once; a failed grant records nothing",
		function()
			local d = S.template()
			local grants = 0
			local function grant(data: any): boolean
				grants += 1
				data.entitlements.paidTier += 1
				return true
			end
			t.eq(processReceipt(d, "dup", grant), "PurchaseGranted", "first call")
			t.eq(processReceipt(d, "dup", grant), "PurchaseGranted", "retry")
			t.eq(grants, 1, "grant fn calls")
			t.eq(d.entitlements.paidTier, 1, "paidTier")
			t.eq(
				processReceipt(d, "fails", function()
					return false
				end),
				"NotYetProcessed",
				"failed grant"
			)
			t.eq(S.hasReceipt(d, "fails"), false, "failed grant not recorded")
		end
	)

	-- Session-locked store (rejoin, server hop, outages) ----------------------------------------------------

	if LockedStore == nil then
		t.skip(
			"rejoin / server hop / outage checks",
			"Server.Data.Util.LockedStore not found (T-012 not merged)"
		)
		return
	end

	local clock = 1793000000
	local function now(): number
		return clock
	end
	local function backend(store: FakeStore, serverId: string): any
		return LockedStore.new(store, {
			template = S.template,
			now = now,
			wait = function() end,
			serverId = serverId,
			loadBackoff = {},
			saveBackoff = {},
			startAutosave = false,
		})
	end

	t.test("first join creates the v1 template", function()
		local store = jsonStore()
		local session = backend(store, "A").startSession(KEY, USER_ID, never)
		t.ok(session ~= nil, "session")
		t.deepEq(session.data, S.template(), "new profile")
		t.eq(store.writes, 1, "one write claims the lock")
		session.saveNow(true)
	end)

	t.test("rejoin keeps coins, MP, tools, pods, pets, rank and every other field", function()
		local store = jsonStore()
		local A = backend(store, "A")
		local s1 = A.startSession(KEY, USER_ID, never)
		populated(s1.data)
		local expected = S.deepCopy(s1.data)
		t.eq(s1.saveNow(true), true, "release save written")
		t.eq(s1.isActive(), false, "session ended on release")
		local s2 = A.startSession(KEY, USER_ID, never)
		t.ok(s2 ~= nil, "rejoin loads")
		t.eq(S.migrate(s2.data), true, "migrate")
		S.reconcile(s2.data)
		t.deepEq(s2.data, expected, "profile after rejoin")
		s2.saveNow(true)
	end)

	t.test("server hop: a second server cannot load while the first holds a fresh lock", function()
		local store = jsonStore()
		local a = backend(store, "A").startSession(KEY, USER_ID, never)
		a.data.coins = 777
		local b, reason = backend(store, "B").startSession(KEY, USER_ID, never)
		t.eq(b, nil, "server B session while A holds the lock")
		t.eq(reason, "locked", "reason")
		a.saveNow(true)
		local b2 = backend(store, "B").startSession(KEY, USER_ID, never)
		t.ok(b2 ~= nil, "B loads after A releases")
		t.eq(b2.data.coins, 777, "B sees A's last save")
		b2.saveNow(true)
	end)

	t.test("server hop: after a stale-lock takeover the old server can no longer save (no dupes)", function()
		local store = jsonStore()
		local a = backend(store, "A").startSession(KEY, USER_ID, never)
		a.data.coins = 100
		a.saveNow(false)
		clock += LockedStore.LOCK_TIMEOUT_SEC + 1
		local b = backend(store, "B").startSession(KEY, USER_ID, never)
		t.ok(b ~= nil, "B takes the stale lock")
		local endReason: string? = nil
		a.onSessionEnd(function(r)
			endReason = r
		end)
		a.data.coins = 1000000 -- a dupe attempt from the old server
		t.eq(a.saveNow(false), false, "old server save refused")
		t.eq(a.isActive(), false, "old session ended")
		t.eq(endReason, "lost", "end reason")
		local saved = HttpService:JSONDecode(store.values[KEY])
		t.eq(saved.data.coins, 100, "stored coins are B's view, not the dupe")
		b.saveNow(true)
	end)

	t.test("a receipt granted on server A is not granted again on server B", function()
		local store = jsonStore()
		local grants = 0
		local function grant(data: any): boolean
			grants += 1
			data.boosts.hypeSec += 600
			return true
		end
		local a = backend(store, "A").startSession(KEY, USER_ID, never)
		processReceipt(a.data, "hop-1", grant)
		a.saveNow(true)
		local b = backend(store, "B").startSession(KEY, USER_ID, never)
		t.eq(processReceipt(b.data, "hop-1", grant), "PurchaseGranted", "retry on B")
		t.eq(grants, 1, "grant fn calls across the hop")
		t.eq(b.data.boosts.hypeSec, 600, "boost granted once")
		b.saveNow(true)
	end)

	t.test("DataStore outage on load: no session, nothing written, existing save untouched", function()
		local store = jsonStore()
		local s = backend(store, "A").startSession(KEY, USER_ID, never)
		populated(s.data)
		s.saveNow(true)
		local before = store.values[KEY]
		store.fail = true
		local s2, reason = backend(store, "A").startSession(KEY, USER_ID, never)
		t.eq(s2, nil, "session during outage")
		t.ok(type(reason) == "string" and string.find(reason, "error", 1, true) == 1, `reason "{reason}"`)
		store.fail = false
		t.eq(store.values[KEY], before, "stored record unchanged")
		local fresh = jsonStore()
		fresh.fail = true
		t.eq(backend(fresh, "A").startSession(KEY, USER_ID, never), nil, "new player during outage")
		t.eq(fresh.values[KEY], nil, "no default profile written during an outage")
	end)

	t.test("DataStore outage on save: old save kept, session stays active, next save succeeds", function()
		local store = jsonStore()
		local s = backend(store, "A").startSession(KEY, USER_ID, never)
		s.data.coins = 10
		s.saveNow(false)
		local before = store.values[KEY]
		store.fail = true
		s.data.coins = 20
		t.eq(s.saveNow(false), false, "save during outage")
		t.eq(store.values[KEY], before, "old save kept")
		t.eq(s.isActive(), true, "session not dropped by a failed save")
		store.fail = false
		t.eq(s.saveNow(true), true, "save after outage")
		t.eq(HttpService:JSONDecode(store.values[KEY]).data.coins, 20, "new value saved")
	end)

	t.test("a corrupt record is never overwritten with defaults", function()
		local store = jsonStore()
		store.values[KEY] = HttpService:JSONEncode("not a profile")
		local s, reason = backend(store, "A").startSession(KEY, USER_ID, never)
		t.eq(s, nil, "session on corrupt record")
		t.eq(reason, "corrupt", "reason")
		t.eq(store.values[KEY], HttpService:JSONEncode("not a profile"), "record unchanged")
	end)

	t.test("a player who leaves during load gets the lock back at once", function()
		local store = jsonStore()
		local calls = 0
		local s, reason = backend(store, "A").startSession(KEY, USER_ID, function()
			calls += 1
			return calls > 1 -- still here for the first try, gone by the time the load returns
		end)
		t.eq(s, nil, "session")
		t.eq(reason, "cancelled", "reason")
		local b = backend(store, "B").startSession(KEY, USER_ID, never)
		t.ok(b ~= nil, "another server loads right away")
		b.saveNow(true)
	end)
end
