--!strict
-- Pure argument checks for C->S remote handlers (architecture section 2 handler rules). Owned by gameplay-programmer.
-- No Roblox services, so qa can unit-test them with fake inputs (NaN, inf, negative, huge, wrong types) in T-025.

local Guard = {}

-- True only for a real, finite number (rejects NaN, +inf, -inf and every non-number).
function Guard.isFinite(x: any): boolean
	return typeof(x) == "number" and x == x and x ~= math.huge and x ~= -math.huge
end

-- True only for a whole number in [lo, hi].
function Guard.isIntInRange(x: any, lo: number, hi: number): boolean
	return Guard.isFinite(x) and x % 1 == 0 and x >= lo and x <= hi
end

-- True only for a string of 1..maxLen bytes. Check this before any other use of the string.
function Guard.isShortString(x: any, maxLen: number): boolean
	return typeof(x) == "string" and #x >= 1 and #x <= maxLen
end

-- Clamps any value to a finite number in [lo, hi]; NaN and non-numbers give `fallback`.
function Guard.clampFinite(x: any, lo: number, hi: number, fallback: number): number
	if not Guard.isFinite(x) then
		return fallback
	end
	return math.clamp(x, lo, hi)
end

return Guard
