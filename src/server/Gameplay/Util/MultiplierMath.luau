--!strict
-- Pure multiplier math (architecture 4a, GDD 4.1). Owned by gameplay-programmer. No Roblox services, so qa can
-- test it directly (NaN inputs, huge pet sums, tier out of range).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local EconomyConfig = require(ReplicatedStorage.Shared.Gameplay.EconomyConfig)

local MultiplierMath = {}

local function finiteOr(x: number, fallback: number): number
	if x ~= x or x == math.huge or x == -math.huge then
		return fallback
	end
	return x
end

-- M = clamp(PetMult x RebirthMult x PaidTier x Vip x Boost, 1, M_CLAMP). Any NaN/inf input or result gives 1.
function MultiplierMath.mp(
	petSum: number,
	rebirths: number,
	paidTier: number,
	vip: boolean,
	hype: boolean
): number
	local petMult = math.min(EconomyConfig.PET_MULT_CAP, 1 + math.max(0, finiteOr(petSum, 0)))
	local m = petMult
		* EconomyConfig.rebirthMult(rebirths)
		* EconomyConfig.paidTierMult(paidTier)
		* (if vip then EconomyConfig.VIP_MP_MULT else 1)
		* (if hype then EconomyConfig.HYPE_MP_MULT else 1)
	m = finiteOr(m, 1)
	return math.clamp(m, 1, EconomyConfig.M_CLAMP)
end

-- Coin multiplier = coinRebirthMult(R) x (2 while the free Coin Snack runs). Pets, tiers and VIP never enter.
function MultiplierMath.coins(rebirths: number, coinSnack: boolean): number
	local c = EconomyConfig.coinRebirthMult(rebirths)
		* (if coinSnack then EconomyConfig.COIN_SNACK_MULT else 1)
	return math.max(1, finiteOr(c, 1))
end

return MultiplierMath
