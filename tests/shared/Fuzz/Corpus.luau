--!strict
-- Bad-argument corpus for the M1 exploit tests (T-025). Owned by qa.
-- Each case is { label, value }. A record (not an array of values) so `nil` cases survive.
-- Every value here must be rejected by the handler/API it is fed to: none may credit MP, coins, tools or wins.

export type Case = { label: string, value: any }

local Corpus = {}

local trapMeta = setmetatable({}, {
	__index = function()
		error("qa trap: handler indexed a client table")
	end,
	__tostring = function()
		return "5"
	end,
	__eq = function()
		return true
	end,
	__lt = function()
		return true
	end,
	__le = function()
		return true
	end,
})

-- Values that are not a finite number at all, or not a number.
Corpus.NON_NUMBERS = {
	{ label = "nil", value = nil },
	{ label = "true", value = true },
	{ label = "false", value = false },
	{ label = "numeric string '5'", value = "5" },
	{ label = "empty string", value = "" },
	{ label = "empty table", value = {} },
	{ label = "array {5}", value = { 5 } },
	{ label = "trap metatable (tostring '5')", value = trapMeta },
	{
		label = "function",
		value = function()
			return 5
		end,
	},
	{ label = "Vector3", value = Vector3.new(5, 5, 5) },
	{ label = "Instance (workspace)", value = workspace },
} :: { Case }

Corpus.BAD_NUMBERS = {
	{ label = "NaN", value = 0 / 0 },
	{ label = "+inf", value = math.huge },
	{ label = "-inf", value = -math.huge },
	{ label = "-1", value = -1 },
	{ label = "0", value = 0 },
	{ label = "-0.5", value = -0.5 },
	{ label = "0.5", value = 0.5 },
	{ label = "1.5", value = 1.5 },
	{ label = "1e308", value = 1e308 },
	{ label = "-1e308", value = -1e308 },
	{ label = "2^53", value = 2 ^ 53 },
	{ label = "2^31", value = 2 ^ 31 },
	{ label = "-2^31", value = -(2 ^ 31) },
	{ label = "1e-300", value = 1e-300 },
} :: { Case }

-- TapBatch count: integer 1..TAP_BATCH_MAX (30). Adds the out-of-range integers.
function Corpus.badTapCounts(): { Case }
	local list = table.clone(Corpus.NON_NUMBERS)
	for _, c in Corpus.BAD_NUMBERS do
		table.insert(list, c)
	end
	table.insert(list, { label = "31 (TAP_BATCH_MAX + 1)", value = 31 })
	table.insert(list, { label = "30.0001", value = 30.0001 })
	table.insert(list, { label = "1000000", value = 1000000 })
	return list
end

-- BuyTool index: must be an integer == ToolIndex + 1 (given ToolIndex on a fresh profile = 1).
function Corpus.badToolIndexes(currentToolIndex: number, toolCount: number): { Case }
	local list = table.clone(Corpus.NON_NUMBERS)
	for _, c in Corpus.BAD_NUMBERS do
		table.insert(list, c)
	end
	table.insert(list, { label = "current tool (already owned)", value = currentToolIndex })
	table.insert(list, { label = "skip one tier (+2)", value = currentToolIndex + 2 })
	table.insert(list, { label = "last tool", value = toolCount })
	table.insert(list, { label = "past last tool", value = toolCount + 1 })
	table.insert(list, { label = "next tool + 0.5", value = currentToolIndex + 1.5 })
	return list
end

-- RequestBossFight bossId: string <= 32 chars and a key in EconomyConfig.BOSSES.
function Corpus.badBossIds(validId: string): { Case }
	local list = table.clone(Corpus.NON_NUMBERS)
	for _, c in Corpus.BAD_NUMBERS do
		table.insert(list, c)
	end
	table.insert(list, { label = "33-char string", value = string.rep("A", 33) })
	table.insert(list, { label = "100,000-char string", value = string.rep("A", 100000) })
	table.insert(list, { label = "valid id + NUL", value = validId .. "\0" })
	table.insert(list, { label = "valid id + space", value = validId .. " " })
	table.insert(list, { label = "valid id upper-cased", value = string.upper(validId) })
	table.insert(list, { label = "valid id lower-cased", value = string.lower(validId) })
	table.insert(list, { label = "'__index'", value = "__index" })
	table.insert(list, { label = "'validate' (an EconomyConfig function name)", value = "validate" })
	table.insert(list, { label = "'1' (array index as string)", value = "1" })
	table.insert(list, { label = "invalid UTF-8", value = "\255\254\253" })
	return list
end

return Corpus
