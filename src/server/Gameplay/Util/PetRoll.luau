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

return PetRoll
