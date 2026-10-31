--!strict
-- GDD rev 2 section 5 egg tables, copied by hand from docs/gdd.md (T-046). Owned by qa.
-- Pets are matched by display name because pet ids are not fixed by docs/architecture.md (1c: `PETS` is keyed by
-- a PetId string chosen in T-027). `pct` is the listed percentage; the config weight must be pct x 100.
-- Lean v1 (D-034): Basic, Shiny, Star and Galaxy ship in sprint 2; Neon and Runway move to T-090 (Update 1).
-- The PetRoll spec checks every egg that EconomyConfig.EGGS contains and ignores the rest.

export type GddPet = { name: string, rarity: string, bonus: number, pct: number }
export type GddEgg = {
	name: string,
	world: number,
	currency: "Coins" | "Robux",
	price: number?, -- coins; nil for Robux eggs (prices live in ProductCatalog)
	restrictedGrant: string?, -- display name of the disclosed fixed pet (Robux eggs, D-016 #4)
	pets: { GddPet },
}

local GddEggs: { [string]: GddEgg } = {
	BasicEgg = {
		name = "Basic Egg",
		world = 1,
		currency = "Coins",
		price = 500,
		pets = {
			{ name = "Puff Pup", rarity = "Common", bonus = 0.05, pct = 50 },
			{ name = "Bubble Bunny", rarity = "Common", bonus = 0.08, pct = 30 },
			{ name = "Glam Hamster", rarity = "Uncommon", bonus = 0.15, pct = 15 },
			{ name = "Shades Gecko", rarity = "Rare", bonus = 0.30, pct = 4.5 },
			{ name = "Mirror Fox", rarity = "Epic", bonus = 0.60, pct = 0.5 },
		},
	},
	ShinyEgg = {
		name = "Shiny Egg",
		world = 1,
		currency = "Coins",
		price = 10000,
		pets = {
			{ name = "Spa Panda", rarity = "Common", bonus = 0.20, pct = 45 },
			{ name = "Gel Penguin", rarity = "Uncommon", bonus = 0.35, pct = 35 },
			{ name = "Disco Duck", rarity = "Rare", bonus = 0.60, pct = 15 },
			{ name = "Sparkle Owl", rarity = "Epic", bonus = 1.20, pct = 4.5 },
			{ name = "Golden Glow Cat", rarity = "Legendary", bonus = 3.00, pct = 0.5 },
		},
	},
	StarEgg = {
		name = "Star Egg",
		world = 1,
		currency = "Robux",
		restrictedGrant = "Starlight Corgi",
		pets = {
			{ name = "Starlight Corgi", rarity = "Rare", bonus = 1.00, pct = 60 },
			{ name = "Aura Lion", rarity = "Epic", bonus = 1.80, pct = 30 },
			{ name = "Halo Dragon", rarity = "Legendary", bonus = 3.50, pct = 9 },
			{ name = "Cosmic Unicorn", rarity = "Mythic", bonus = 8.00, pct = 1 },
		},
	},
	NeonEgg = {
		name = "Neon Egg",
		world = 2,
		currency = "Coins",
		price = 250000,
		pets = {
			{ name = "Neon Moth", rarity = "Common", bonus = 0.50, pct = 45 },
			{ name = "Laser Lizard", rarity = "Uncommon", bonus = 0.80, pct = 35 },
			{ name = "Runway Raccoon", rarity = "Rare", bonus = 1.30, pct = 15 },
			{ name = "Chrome Shark", rarity = "Epic", bonus = 2.20, pct = 4.5 },
			{ name = "Spotlight Phoenix", rarity = "Legendary", bonus = 5.00, pct = 0.5 },
		},
	},
	RunwayEgg = {
		name = "Runway Egg",
		world = 2,
		currency = "Coins",
		price = 5000000,
		pets = {
			{ name = "Velvet Llama", rarity = "Common", bonus = 1.00, pct = 45 },
			{ name = "Glitter Gorilla", rarity = "Uncommon", bonus = 1.50, pct = 35 },
			{ name = "Hologram Tiger", rarity = "Rare", bonus = 2.50, pct = 15 },
			{ name = "Prism Whale", rarity = "Epic", bonus = 4.00, pct = 4.5 },
			{ name = "Crowned Griffin", rarity = "Legendary", bonus = 8.00, pct = 0.5 },
		},
	},
	GalaxyEgg = {
		name = "Galaxy Egg",
		world = 2,
		currency = "Robux",
		restrictedGrant = "Nebula Fox",
		pets = {
			{ name = "Nebula Fox", rarity = "Rare", bonus = 3.00, pct = 60 },
			{ name = "Comet Wolf", rarity = "Epic", bonus = 5.00, pct = 30 },
			{ name = "Supernova Dragon", rarity = "Legendary", bonus = 9.00, pct = 9 },
			{ name = "Galaxy Kraken", rarity = "Mythic", bonus = 20.00, pct = 1 },
		},
	},
}

return GddEggs
