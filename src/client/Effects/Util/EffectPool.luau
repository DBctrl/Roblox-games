--!strict
-- EffectPool: fixed-size pools of invisible anchored emitter parts plus one shared particle budget.
-- Helper for Effects controllers (not a service: it lives in Util/, so the bootstrap does not load it).
-- All instances are created once in `new` (call it from a controller's Init; it never yields). When a pool is
-- busy or the budget is full, `emit` drops the effect instead of creating anything. No per-frame work.

local EffectsConfig = require(game:GetService("ReplicatedStorage").Shared.Physics.EffectsConfig)

export type Look = EffectsConfig.EmitterLook

type Slot = {
	part: BasePart,
	emitter: ParticleEmitter,
	busy: boolean,
}

export type Pool = {
	name: string,
	slots: { Slot },
	cursor: number,
	holdSeconds: number,
}

local EffectPool = {}

-- Shared across every pool: particles emitted and still within their max lifetime.
local particlesAlive = 0

local function buildEmitter(look: Look): ParticleEmitter
	local emitter = Instance.new("ParticleEmitter")
	emitter.Enabled = false -- only bursts through :Emit(), never a continuous rate
	emitter.Rate = 0
	emitter.Texture = look.texture
	emitter.Color = ColorSequence.new(look.color)
	emitter.LightEmission = look.lightEmission
	emitter.Size = NumberSequence.new(look.sizeStart, look.sizeEnd)
	emitter.Transparency = NumberSequence.new(0, 1)
	emitter.Lifetime = NumberRange.new(look.lifetimeMin, look.lifetimeMax)
	emitter.Speed = NumberRange.new(look.speedMin, look.speedMax)
	emitter.SpreadAngle = Vector2.new(look.spread, look.spread)
	emitter.Acceleration = Vector3.new(0, -look.gravity, 0)
	emitter.Drag = look.drag
	emitter.LockedToPart = false
	return emitter
end

function EffectPool.new(name: string, size: number, look: Look, parent: Instance): Pool
	local slots: { Slot } = {}
	for i = 1, size do
		local part = Instance.new("Part")
		part.Name = `{name}_{i}`
		part.Size = Vector3.new(0.2, 0.2, 0.2)
		part.Transparency = 1
		part.Anchored = true
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		part.CastShadow = false
		part.Locked = true
		local emitter = buildEmitter(look)
		emitter.Parent = part
		part.Parent = parent
		slots[i] = { part = part, emitter = emitter, busy = false }
	end
	return {
		name = name,
		slots = slots,
		cursor = 0,
		holdSeconds = look.lifetimeMax,
	}
end

local function takeSlot(pool: Pool): Slot?
	local count = #pool.slots
	for _ = 1, count do
		pool.cursor = pool.cursor % count + 1
		local slot = pool.slots[pool.cursor]
		if not slot.busy then
			return slot
		end
	end
	return nil
end

-- Bursts `count` particles at `position`. Trims the burst to the remaining budget; returns particles emitted.
function EffectPool.emit(pool: Pool, position: Vector3, count: number): number
	local n = math.min(math.floor(count), EffectsConfig.MAX_PARTICLES_ALIVE - particlesAlive)
	if n < 1 then
		return 0
	end
	local slot = takeSlot(pool)
	if not slot then
		return 0
	end
	slot.busy = true
	particlesAlive += n
	slot.part.CFrame = CFrame.new(position)
	slot.emitter:Emit(n)
	task.delay(pool.holdSeconds, function()
		particlesAlive -= n
		slot.busy = false
	end)
	return n
end

function EffectPool.particlesAlive(): number
	return particlesAlive
end

return EffectPool
