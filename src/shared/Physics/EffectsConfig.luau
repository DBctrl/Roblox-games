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

-- Celebration sparkle bursts (PlayEffect Rebirth, Purchase). RankUp is CinematicController's (T-043).
EffectsConfig.Celebrate = table.freeze({
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
	-- Rank-up confetti (T-043): 3 bursts for the local moment + 2 nearby moments at once.
	Confetti = table.freeze({
		size = 6,
		look = table.freeze({
			texture = SPARKLE_TEXTURE,
			color = Color3.fromRGB(255, 120, 200),
			lightEmission = 0.6,
			sizeStart = 0.7,
			sizeEnd = 0.5,
			lifetimeMin = 1.2,
			lifetimeMax = 1.8,
			speedMin = 10,
			speedMax = 20,
			spread = 70,
			gravity = 18,
			drag = 1.5,
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

-- Rank-up moment (T-043, GDD 7: 3 s, spotlight, confetti, camera orbit, the new look pops on).
-- The local player gets the camera orbit; other players within `nearbyDistance` of the camera see the spotlight,
-- confetti and look pop on that character with no camera change. One render-step function drives everything
-- (no tweens). The orbit is skipped (spotlight + confetti only) while the local player is in a duel.
EffectsConfig.RankUp = table.freeze({
	duration = 3, -- seconds
	nearbyDistance = 90, -- studs from the camera for other players' rank-ups
	maxRigs = 3, -- spotlight + highlight rigs alive at once (local + 2 nearby); extra rank-ups get confetti only
	orbitRadius = 11, -- studs from the HumanoidRootPart
	orbitHeight = 3.5, -- studs above the root
	orbitTurns = 0.75, -- turns around the character over the whole moment
	orbitFov = 60,
	blendIn = 0.35, -- seconds from the player's camera into the orbit
	blendOut = 0.45, -- seconds from the orbit back to the player's camera
	lookHeight = 1.2, -- studs above the root the camera looks at
	beamHeight = 26, -- spotlight beam length, studs
	beamWidth = 7,
	beamTransparency = 0.82, -- beam at full strength (1 = invisible)
	beamColor = Color3.fromRGB(255, 244, 200),
	lightBrightness = 6,
	lightRange = 30,
	lightAngle = 40,
	popAt = 0.6, -- seconds in: the look "pops" (highlight flash + confetti burst)
	popFade = 0.7, -- seconds the highlight flash takes to fade out
	popColor = Color3.fromRGB(255, 230, 120),
	confettiBursts = { 0.6, 1.4, 2.2 }, -- seconds in
	confettiPerBurst = 45,
	confettiNearbyPerBurst = 25,
	confettiHeight = 7, -- studs above the root
	titleText = "RANK UP!",
})

-- Hatch reveal (T-045, GDD 5: about 2 s, skippable). Shows only what the server's HatchResult says.
EffectsConfig.Hatch = table.freeze({
	wobbleTime = 1.0, -- egg wobble before it cracks
	flashTime = 0.15, -- white flash
	revealStagger = 0.12, -- seconds between the cards of a x3 hatch
	popTime = 0.25, -- each card's scale-in
	holdTime = 0.75, -- cards stay this long after the last pop (total about 2 s for x1, 2.2 s for x3)
	skipHoldTime = 0.6, -- after Skip, the cards show this long (or until Skip/tap is pressed again)
	maxReveals = 3, -- HatchEgg count is 1 or 3
	maxQueued = 3, -- HatchResults waiting behind the current one; more are dropped (the inventory still has them)
	wobbleDegrees = 14,
	wobbleSpeed = 22, -- radians/s, grows over the wobble
	eggColor = Color3.fromRGB(255, 236, 200),
})

-- Rarity colors for the hatch cards and fallback pet spheres.
EffectsConfig.RarityColors = table.freeze({
	Common = Color3.fromRGB(200, 200, 210),
	Uncommon = Color3.fromRGB(110, 220, 120),
	Rare = Color3.fromRGB(80, 160, 255),
	Epic = Color3.fromRGB(190, 100, 255),
	Legendary = Color3.fromRGB(255, 190, 40),
	Mythic = Color3.fromRGB(255, 80, 140),
} :: { [string]: Color3 })
EffectsConfig.DEFAULT_RARITY_COLOR = Color3.fromRGB(230, 230, 240)

-- Pet follow (T-044, architecture 7: within 120 studs, <= 36 models alive, one Heartbeat loop, BulkMoveTo).
EffectsConfig.Pets = table.freeze({
	renderRadius = 120, -- studs from the local character (camera if no character)
	maxModels = 36, -- pet models alive (shown + cached) at any time
	maxPerPlayer = 6, -- equip slots max (3 + 2 rebirth + 1 VIP)
	maxIdLength = 32, -- longer ids in EquippedPets are ignored
	refreshInterval = 0.5, -- seconds between re-picking which pets to show
	followSharpness = 8, -- higher = snappier follow (exponential smoothing per second)
	snapDistance = 40, -- studs; a pet further than this from its target teleports (respawn, teleport)
	rowSpacing = 3.2, -- studs between pets in a row behind the owner
	rowBack = 4.5, -- studs behind the owner for the first row
	rowDepth = 3, -- studs between rows
	perRow = 3,
	floatHeight = 0.5, -- studs above the root, before bob
	bobAmplitude = 0.45,
	bobSpeed = 3, -- radians/s
	sphereSize = 1.8, -- fallback ball diameter when ReplicatedStorage.Assets.Pets.<petId> is missing
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

-- Pure: parses the EquippedPets attribute ("PuffPup,BubbleBunny") into at most `Pets.maxPerPlayer` ids.
-- Non-strings, empty entries and over-long ids are skipped. Order is kept (it decides the formation slot).
function EffectsConfig.parseEquippedPets(value: unknown): { string }
	local out: { string } = {}
	if type(value) ~= "string" or value == "" then
		return out
	end
	local cfg = EffectsConfig.Pets
	for id in string.gmatch(value, "[^,]+") do
		local trimmed = string.match(id, "^%s*(.-)%s*$") or ""
		if trimmed ~= "" and #trimmed <= cfg.maxIdLength then
			table.insert(out, trimmed)
			if #out >= cfg.maxPerPlayer then
				break
			end
		end
	end
	return out
end

-- Pure: the offset (owner space: +X right, +Z back) of pet `index` (1-based) out of `count` pets.
-- Rows of `perRow` behind the owner, each row centered.
function EffectsConfig.petOffset(index: number, count: number): Vector3
	local cfg = EffectsConfig.Pets
	local row = math.floor((index - 1) / cfg.perRow)
	local inRow = math.min(cfg.perRow, count - row * cfg.perRow)
	local col = (index - 1) % cfg.perRow
	local x = (col - (inRow - 1) / 2) * cfg.rowSpacing
	local z = cfg.rowBack + row * cfg.rowDepth
	return Vector3.new(x, cfg.floatHeight, z)
end

-- Pure: smoothing factor for exponential follow over `dt` seconds (0..1, frame-rate independent).
function EffectsConfig.followAlpha(dt: number): number
	if dt ~= dt or dt <= 0 then
		return 0
	end
	return 1 - math.exp(-EffectsConfig.Pets.followSharpness * dt)
end

-- Pure: smoothstep 0..1.
function EffectsConfig.smooth(t: number): number
	local x = math.clamp(t, 0, 1)
	return x * x * (3 - 2 * x)
end

-- Pure: camera position on the rank-up orbit at `elapsed` seconds around `center`, starting at `startAngle`
-- (radians, so the orbit begins behind the camera's current side).
function EffectsConfig.orbitPosition(center: Vector3, startAngle: number, elapsed: number): Vector3
	local cfg = EffectsConfig.RankUp
	local angle = startAngle + (elapsed / cfg.duration) * cfg.orbitTurns * 2 * math.pi
	return center
		+ Vector3.new(math.cos(angle) * cfg.orbitRadius, cfg.orbitHeight, math.sin(angle) * cfg.orbitRadius)
end

-- Pure: (seconds until the cards start to pop, total length) of the reveal for a hatch of `count` pets.
function EffectsConfig.hatchTimes(count: number): (number, number)
	local h = EffectsConfig.Hatch
	local n = math.clamp(math.floor(count), 1, h.maxReveals)
	local revealStart = h.wobbleTime + h.flashTime
	local lastPop = revealStart + (n - 1) * h.revealStagger + h.popTime
	return revealStart, lastPop + h.holdTime
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
	-- Rank-up: a local moment's confetti that is alive at once must fit in the cap with tap sparkles.
	local r = EffectsConfig.RankUp
	assert(r.blendIn + r.blendOut < r.duration, "rank-up blends longer than the moment")
	local confetti = EffectsConfig.Pools.Confetti
	assert(#r.confettiBursts <= confetti.size, "confetti pool too small for one rank-up")
	assert(
		r.confettiPerBurst * #r.confettiBursts + worstCase <= EffectsConfig.MAX_PARTICLES_ALIVE,
		"rank-up confetti + tap sparkles exceed cap"
	)
	-- Hatch: about 2 s for every hatch size.
	local _, total1 = EffectsConfig.hatchTimes(1)
	local _, total3 = EffectsConfig.hatchTimes(EffectsConfig.Hatch.maxReveals)
	assert(total1 >= 1.5 and total3 <= 2.6, "hatch animation is not about 2 s")
	-- Pets: the cap must cover at least the local player's full formation.
	local p = EffectsConfig.Pets
	assert(p.maxModels >= p.maxPerPlayer, "pet model cap below one player's slots")
	assert(p.maxModels <= 36, "pet model cap above architecture 7 budget (36)")
	assert(p.renderRadius <= 120, "pet render radius above architecture 7 budget (120)")
end

return table.freeze(EffectsConfig)
