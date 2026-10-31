--!strict
-- Pure pet roll (architecture 4b, QA-F7): the roller PetService really uses. Owned by gameplay-programmer.
-- Server only: PetService owns the one `Random` and passes it in, so the client never sees or sends a seed. No Roblox services, so qa can feed fixed rolls or
-- a seeded `Random` and check 100,000 rolls against the listed odds (T-046).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local EconomyConfig = require(ReplicatedStorage.Shared.Gameplay.EconomyConfig)

type EggPet = EconomyConfig.EggPet

local PetRoll = {}

-- Sum of the weights in `entries` (10,000 for every validated egg).
function PetRoll.total(entries: { EggPet }): number
	local sum = 0
	for _, entry in entries do
		sum += entry.weight
	end
	return sum
end

-- Maps a roll `r` in 1..total to a pet id by walking the weights in table order. Out-of-range rolls clamp,
-- so a bad roll can never return nil for a valid table.
function PetRoll.pickWithRoll(entries: { EggPet }, r: number): string
	local total = PetRoll.total(entries)
	local roll = math.clamp(math.floor(r), 1, math.max(1, total))
	local acc = 0
	for _, entry in entries do
		acc += entry.weight
		if roll <= acc then
			return entry.petId
		end
	end
	return entries[#entries].petId
end

-- One weighted roll with the server's Random.
function PetRoll.pick(pets: { EggPet }, rng: Random): string
	return PetRoll.pickWithRoll(pets, rng:NextInteger(1, math.max(1, PetRoll.total(pets))))
end

-- One Robux-egg hatch with pity (architecture 4b, GDD 5). `pity` = hatches since the last Legendary+.
-- On the pity hatch (pity >= pityAt - 1) the roll uses EconomyConfig.pityOdds (Legendary 90 / Mythic 10).
-- Returns the pet id, the new counter (0 after any Legendary+, else +1) and whether pity forced this hatch.
-- A 3-pack calls this 3 times in order, feeding the counter through, so pity can trigger inside the pack.
function PetRoll.pickWithPity(egg: EconomyConfig.Egg, pity: number, rng: Random): (string, number, boolean)
	local current = if pity == pity and pity >= 0 and pity < math.huge then math.floor(pity) else 0
	local forced = egg.pityAt ~= nil and current >= egg.pityAt - 1
	local petId = PetRoll.pick(EconomyConfig.nextHatchOdds(egg, current), rng)
	local hit = EconomyConfig.isPityHit(EconomyConfig.PETS[petId].rarity)
	return petId, if hit then 0 else current + 1, forced
end

return PetRoll
