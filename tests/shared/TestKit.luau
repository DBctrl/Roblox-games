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

return TestKit
