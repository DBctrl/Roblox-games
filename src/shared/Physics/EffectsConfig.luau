--!strict
-- EffectsConfig: every number the client effects use (pool sizes, particle budgets, timings, looks).
-- Owned by physics-programmer. Pure data and pure functions: no Roblox services, no requires.
-- Read by src/client/Effects only. Nothing here decides game state; effects are cosmetic (architecture 0, 7).

export type EmitterLook = {
	texture: string,
	color: Color3,
	lightEmission: number,
	sizeStart: number,
	sizeEnd: number,
	lifetimeMin: number, -- seconds
	lifetimeMax: number, -- seconds; also how long a pooled slot and its particles stay reserved
	speedMin: number, -- studs/s
	speedMax: number,
	spread: number, -- degrees, both axes
	gravity: number, -- studs/s^2, downwards (0 = float)
	drag: number,
}

export type PoolSpec = {
	size: number, -- pooled instances, created once in Init; when all are busy the effect is dropped
	look: EmitterLook,
}

local EffectsConfig = {}

-- Budgets (architecture section 7). The particle cap counts every particle we emit until its max lifetime ends.
EffectsConfig.MAX_PARTICLES_ALIVE = 300
-- Effects further than this from the camera are skipped (cheap culling; the server already filters by world).
EffectsConfig.MAX_EFFECT_DISTANCE = 220

-- Tap sparkles (local tap input only). Mirrors TapController's local cap of 12 taps/s (architecture 1d #26).
EffectsConfig.Tap = table.freeze({
	maxPerSecond = 12,
	particlesPerTap = 6,
	rayLength = 300, -- studs from the camera; on a miss the sparkle pops at the character instead
	characterOffsetY = 2, -- studs above HumanoidRootPart for the fallback spot
})

-- Coin bursts (PlayEffect BossWin, DailyReward, Donation). Count grows with log10(amount), clamped.
EffectsConfig.CoinBurst = table.freeze({
	baseParticles = 10,
	perDecade = 4,
	minParticles = 10,
	maxParticles = 60,
	donationPerTier = 10, -- Donation tier 1..5 -> 10..50
	heightOffset = 3,
})

-- Celebration sparkle bursts (PlayEffect RankUp, Rebirth, Purchase). Cinematics are CinematicController's (T-023+).
EffectsConfig.Celebrate = table.freeze({
	RankUp = 40,
	Rebirth = 50,
	Purchase = 25,
	heightOffset = 3,
})

-- TODO(verify-api): rbxasset texture paths below are Roblox's built-in sparkle texture; confirm it renders in
-- Studio (/toolcheck). builder may swap in a logged custom coin texture later (docs/asset-briefs/).
local SPARKLE_TEXTURE = "rbxasset://textures/particles/sparkles_main.dds"

EffectsConfig.Pools = table.freeze({
	TapSparkle = table.freeze({
		size = 20,
		look = table.freeze({
			texture = SPARKLE_TEXTURE,
			color = Color3.fromRGB(255, 240, 160),
			lightEmission = 1,
			sizeStart = 0.6,
			sizeEnd = 0,
			lifetimeMin = 0.3,
			lifetimeMax = 0.5,
			speedMin = 6,
			speedMax = 10,
			spread = 180,
			gravity = 0,
			drag = 4,
		}),
	}),
	CoinBurst = table.freeze({
		size = 6,
		look = table.freeze({
			texture = SPARKLE_TEXTURE,
			color = Color3.fromRGB(255, 196, 40),
			lightEmission = 0.4,
			sizeStart = 1,
			sizeEnd = 0.4,
			lifetimeMin = 0.8,
			lifetimeMax = 1.2,
			speedMin = 14,
			speedMax = 22,
			spread = 50,
			gravity = 40,
			drag = 1,
		}),
	}),
	Celebrate = table.freeze({
		size = 4,
		look = table.freeze({
			texture = SPARKLE_TEXTURE,
			color = Color3.fromRGB(200, 140, 255),
			lightEmission = 1,
			sizeStart = 1.2,
			sizeEnd = 0,
			lifetimeMin = 0.8,
			lifetimeMax = 1.4,
			speedMin = 8,
			speedMax = 16,
			spread = 180,
			gravity = 6,
			drag = 2,
		}),
	}),
})

-- Pure: particle count for a coin burst of `amount` coins/MP. Safe on NaN, inf and negatives.
function EffectsConfig.coinParticles(amount: number?): number
	local c = EffectsConfig.CoinBurst
	local n = c.minParticles
	if type(amount) == "number" and amount == amount and amount > 1 and amount < math.huge then
		n = c.baseParticles + math.floor(math.log10(amount)) * c.perDecade
	end
	return math.clamp(n, c.minParticles, c.maxParticles)
end

-- Pure: particle count for a Donation tier (1..5). Anything else gets tier 1.
function EffectsConfig.donationParticles(tier: number?): number
	local t = 1
	if type(tier) == "number" and tier == tier then
		t = math.clamp(math.floor(tier), 1, 5)
	end
	return t * EffectsConfig.CoinBurst.donationPerTier
end

-- Asserts the budgets hold together (qa can call this in tests).
function EffectsConfig.validate()
	for name, spec: PoolSpec in EffectsConfig.Pools do
		assert(spec.size >= 1, `pool {name} needs at least 1 slot`)
		assert(spec.look.lifetimeMin <= spec.look.lifetimeMax, `pool {name} lifetime range`)
	end
	-- Tap sparkles alone at the max tap rate must fit well inside the cap.
	local tap = EffectsConfig.Pools.TapSparkle.look
	local worstCase = math.ceil(EffectsConfig.Tap.maxPerSecond * tap.lifetimeMax)
		* EffectsConfig.Tap.particlesPerTap
	assert(
		worstCase <= EffectsConfig.MAX_PARTICLES_ALIVE / 2,
		"tap sparkles use more than half the particle cap"
	)
	assert(
		EffectsConfig.CoinBurst.maxParticles <= EffectsConfig.MAX_PARTICLES_ALIVE,
		"coin burst exceeds cap"
	)
	assert(
		EffectsConfig.donationParticles(5) <= EffectsConfig.MAX_PARTICLES_ALIVE,
		"donation burst exceeds cap"
	)
end

return table.freeze(EffectsConfig)
