--!strict
-- Display formatting for numbers shown to players. Owned by integration-programmer.
-- Pure functions only (no Roblox services), so server, client and qa unit tests can all call them.
-- Never returns "nan" or "inf": NaN shows as "0" and infinities as "999Qa+"-style caps, so a bad value
-- can't break a label.

local NumberFormat = {}

local SUFFIXES = { "K", "M", "B", "T", "Qa" } -- 1e3, 1e6, 1e9, 1e12, 1e15
local EPSILON = 1e-9 -- absorbs float error before truncating (e.g. 1.2 / 1 * 10 = 11.999...)

local function isFinite(n: number): boolean
	return n == n and n ~= math.huge and n ~= -math.huge
end

-- Truncates (never rounds up, so 999,999 shows "999.9K", not "1000K") to `decimals` places and drops trailing
-- zeros: 1.50 -> "1.5", 2.00 -> "2".
local function fixed(value: number, decimals: number): string
	local scale = 10 ^ decimals
	local truncated = math.floor(value * scale + EPSILON) / scale
	local text = string.format(`%.{decimals}f`, truncated)
	if decimals > 0 then
		-- Two steps so "0.00" becomes "0", not "" ("%.?0+$" would also eat the leading zero).
		text = string.gsub(text, "0+$", "")
		text = string.gsub(text, "%.$", "")
	end
	return text
end

-- Short form with K/M/B/T/Qa suffixes: 999 -> "999", 1500 -> "1.5K", 2.25e6 -> "2.2M", 1e15 -> "1Qa",
-- 1e18 -> "1000Qa". Values under 1000 are shown as whole numbers (floored). `decimals` defaults to 1 (0..3).
function NumberFormat.abbreviate(n: number, decimals: number?): string
	if n ~= n then
		return "0"
	end
	local places = math.clamp(math.floor(decimals or 1), 0, 3)
	local sign = if n < 0 then "-" else ""
	local a = math.abs(n)
	if a == math.huge then
		return sign .. "999" .. SUFFIXES[#SUFFIXES] .. "+"
	end
	if a < 1000 then
		return sign .. string.format("%d", math.floor(a + EPSILON))
	end
	local tier = 0
	while tier < #SUFFIXES and a >= 1000 ^ (tier + 1) do
		tier += 1
	end
	return sign .. fixed(a / 1000 ^ tier, places) .. SUFFIXES[tier]
end

-- Full number with thousands separators: 1234567 -> "1,234,567". Floors toward zero. Safe up to 1e18.
function NumberFormat.commas(n: number): string
	if not isFinite(n) then
		return if n ~= n then "0" else NumberFormat.abbreviate(n)
	end
	local sign = if n < 0 then "-" else ""
	local digits = string.format("%.0f", math.floor(math.abs(n) + EPSILON))
	local out = string.reverse((string.gsub(string.reverse(digits), "(%d%d%d)", "%1,")))
	if string.sub(out, 1, 1) == "," then
		out = string.sub(out, 2)
	end
	return sign .. out
end

-- Countdown text: 59 -> "0:59", 299 -> "4:59", 3903 -> "1:05:03". Negative or NaN -> "0:00".
function NumberFormat.duration(seconds: number): string
	if not isFinite(seconds) or seconds <= 0 then
		return "0:00"
	end
	local total = math.floor(seconds)
	local h = total // 3600
	local m = (total % 3600) // 60
	local s = total % 60
	if h > 0 then
		return string.format("%d:%02d:%02d", h, m, s)
	end
	return string.format("%d:%02d", m, s)
end

-- Multiplier label: 2 -> "x2", 1.25 -> "x1.25", 12500 -> "x12.5K". Two decimals max, truncated.
function NumberFormat.multiplier(m: number): string
	if not isFinite(m) then
		return "x1"
	end
	if math.abs(m) >= 1000 then
		return "x" .. NumberFormat.abbreviate(m)
	end
	return "x" .. fixed(m, 2)
end

-- Egg odds from an integer weight out of 10,000 (EconomyConfig): 4500 -> "45%", 50 -> "0.5%", 1 -> "0.01%".
-- Exact: weights are integers, so two decimals show every weight without rounding.
function NumberFormat.oddsPercent(weight: number): string
	if not isFinite(weight) or weight <= 0 then
		return "0%"
	end
	return fixed(weight / 100, 2) .. "%"
end

return table.freeze(NumberFormat)
