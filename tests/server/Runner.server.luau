--!strict
-- qa test runner. Synced only by test.project.json (D-004), never shipped.
-- In Studio: `rojo serve test.project.json`, then Run (F8) for config/unit specs, or Play (F5) so the
-- player-based specs (Exploit*.spec) get a real Player. Results print to Output as one line per test plus a
-- summary; the summary line starts with "QA RESULT" so a Studio MCP console read can grep it.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local TestKit = require(ReplicatedStorage:WaitForChild("QaTests"):WaitForChild("TestKit"))

local specsFolder = script.Parent:WaitForChild("Specs")

local specs = {}
for _, child in specsFolder:GetChildren() do
	if child:IsA("ModuleScript") and string.match(child.Name, "%.spec$") then
		table.insert(specs, child)
	end
end
table.sort(specs, function(a, b)
	return a.Name < b.Name
end)

local pass, fail, skip = 0, 0, 0
for _, module in specs do
	local suite = TestKit.newSuite(module.Name)
	local ok, err = pcall(function()
		local spec = (require :: any)(module)
		spec(suite)
	end)
	if not ok then
		table.insert(suite.results, { name = "(load)", status = "FAIL", detail = tostring(err) })
	end
	for _, r in suite.results do
		if r.status == "PASS" then
			pass += 1
			print(`[qa] PASS {suite.name} :: {r.name}`)
		elseif r.status == "SKIP" then
			skip += 1
			print(`[qa] SKIP {suite.name} :: {r.name} ({r.detail})`)
		else
			fail += 1
			warn(`[qa] FAIL {suite.name} :: {r.name}\n{r.detail}`)
		end
	end
end

local summary =
	`QA RESULT {if fail == 0 then "PASS" else "FAIL"}: {pass} passed, {fail} failed, {skip} skipped`
if fail == 0 then
	print(summary)
else
	warn(summary)
end
