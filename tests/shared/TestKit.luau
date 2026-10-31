--!strict
-- Tiny test harness for "Aura Up!" Studio tests. Owned by qa.
-- Self-contained on purpose: TestEZ would come through wally, and wally is not installed in the cloud
-- session (D-022), so the tests must not depend on Packages.
--
-- A spec is a ModuleScript named `*.spec` that returns `function(t: TestKit.Suite)`. Inside:
--   t.test("name", function() t.eq(actual, expected, "label") end)
--   t.skip("name", "reason")  -- pending work (for example a service that is not merged yet)
-- Any error inside a test (including a failed t.* check) fails that test only.

export type Result = { name: string, status: "PASS" | "FAIL" | "SKIP", detail: string? }

export type Suite = {
	name: string,
	results: { Result },
	test: (name: string, fn: () -> ()) -> (),
	skip: (name: string, reason: string) -> (),
	ok: (cond: any, label: string) -> (),
	eq: (actual: any, expected: any, label: string) -> (),
	near: (actual: number, expected: number, label: string, tol: number?) -> (),
	fails: (fn: () -> (), label: string) -> (),
}

local TestKit = {}

local function show(v: any): string
	if type(v) == "string" then
		return string.format("%q", v)
	end
	return tostring(v)
end

function TestKit.newSuite(name: string): Suite
	local suite = {} :: Suite
	suite.name = name
	suite.results = {}

	function suite.test(testName: string, fn: () -> ())
		local ok, err = xpcall(fn, function(e)
			return tostring(e) .. "\n" .. debug.traceback(nil, 2)
		end)
		table.insert(
			suite.results,
			{ name = testName, status = if ok then "PASS" else "FAIL", detail = if ok then nil else err }
		)
	end

	function suite.skip(testName: string, reason: string)
		table.insert(suite.results, { name = testName, status = "SKIP", detail = reason })
	end

	function suite.ok(cond: any, label: string)
		if not cond then
			error(`check failed: {label}`, 2)
		end
	end

	function suite.eq(actual: any, expected: any, label: string)
		if actual ~= expected then
			error(`{label}: expected {show(expected)}, got {show(actual)}`, 2)
		end
	end

	function suite.near(actual: number, expected: number, label: string, tol: number?)
		local eps = tol or 1e-9 * math.max(1, math.abs(expected))
		if type(actual) ~= "number" or actual ~= actual or math.abs(actual - expected) > eps then
			error(`{label}: expected {expected} (+/- {eps}), got {show(actual)}`, 2)
		end
	end

	function suite.fails(fn: () -> (), label: string)
		local ok = pcall(fn)
		if ok then
			error(`{label}: expected an error, got none`, 2)
		end
	end

	return suite
end

-- Returns the first non-nil field of `entry` among `names` (EconomyConfig entry field names are not fixed by
-- docs/architecture.md, see qa finding QA-F4), or errors with the names tried.
function TestKit.field(entry: any, names: { string }, label: string): any
	if type(entry) ~= "table" then
		error(`{label}: entry is {typeof(entry)}, not a table`, 2)
	end
	for _, n in names do
		if entry[n] ~= nil then
			return entry[n]
		end
	end
	error(`{label}: none of the fields {table.concat(names, "/")} found`, 2)
end

-- Path of the first difference between two plain-data values ("" if equal). Tables compare key by key, both ways.
function TestKit.diff(a: any, b: any, path: string?): string?
	local here = path or "$"
	if type(a) ~= "table" or type(b) ~= "table" then
		if a == b or (a ~= a and b ~= b) then
			return nil
		end
		return `{here}: {show(a)} vs {show(b)}`
	end
	for k, v in a do
		local d = TestKit.diff(v, b[k], `{here}.{tostring(k)}`)
		if d then
			return d
		end
	end
	for k, v in b do
		if a[k] == nil then
			return `{here}.{tostring(k)}: nil vs {show(v)}`
		end
	end
	return nil
end

-- Errors with the first difference if `actual` and `expected` are not deep-equal.
function TestKit.deepEq(actual: any, expected: any, label: string)
	local d = TestKit.diff(actual, expected)
	if d then
		error(`{label}: differs at {d}`, 2)
	end
end

-- `require` that returns nil instead of erroring, so a spec can SKIP when a module is not merged yet.
function TestKit.tryRequire(parent: Instance?, path: { string }): any
	local node: Instance? = parent
	for _, name in path do
		node = node and node:FindFirstChild(name)
	end
	if node == nil or not node:IsA("ModuleScript") then
		return nil
	end
	local ok, mod = pcall(require, node)
	if not ok then
		error(`require {table.concat(path, ".")} failed: {mod}`, 2)
	end
	return mod
end

-- First function field of `mod` among `names`, or nil. For test seams whose name is not fixed yet (QA-F8, QA-F9).
function TestKit.firstFn(mod: any, names: { string }): ((...any) -> ...any)?
	if type(mod) ~= "table" then
		return nil
	end
	for _, n in names do
		if type(mod[n]) == "function" then
			return mod[n]
		end
	end
	return nil
end

-- Players with `DataLoaded`, waiting up to `timeoutSec` (default 20) for at least `n` of them. Returns what it has.
function TestKit.loadedPlayers(n: number, timeoutSec: number?): { Player }
	local Players = game:GetService("Players")
	local deadline = os.clock() + (timeoutSec or 20)
	local list: { Player } = {}
	repeat
		list = {}
		for _, p in Players:GetPlayers() do
			if p:GetAttribute("DataLoaded") == true then
				table.insert(list, p)
			end
		end
		if #list >= n then
			break
		end
		task.wait(0.25)
	until os.clock() > deadline
	return list
end

-- Replaces `tbl[key]` with `value` for a test (fault injection). Returns a restore function, or nil when the table
-- is frozen or the write fails (the caller SKIPs). Always call the restore, also on failure (use `TestKit.with`).
function TestKit.patch(tbl: any, key: string, value: any): (() -> ())?
	if type(tbl) ~= "table" or table.isfrozen(tbl) then
		return nil
	end
	local old = tbl[key]
	local ok = pcall(function()
		tbl[key] = value
	end)
	if not ok then
		return nil
	end
	return function()
		tbl[key] = old
	end
end

-- Runs `fn`, then every restore in `restores` (nil entries skipped), then re-raises any error from `fn`.
function TestKit.with(restores: { (() -> ())? }, fn: () -> ())
	local ok, err = pcall(fn)
	local top = 0
	for i in restores do
		top = math.max(top, i)
	end
	for i = top, 1, -1 do
		local r = restores[i]
		if r then
			r()
		end
	end
	if not ok then
		error(err, 0)
	end
end

-- Number of keys in a table (inventory maps).
function TestKit.count(t: any): number
	local n = 0
	if type(t) == "table" then
		for _ in t do
			n += 1
		end
	end
	return n
end

return TestKit
