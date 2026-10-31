--!strict
-- Per-player, per-remote token bucket for every C->S handler. Owned by integration-programmer.
-- Reads `rate` (tokens refilled per second) and `burst` (bucket size) from Remotes.Definitions, so the limits
-- live in one place (docs/architecture.md section 2). Over-limit calls are dropped silently: no reply, no error,
-- no log spam. State is cleared on PlayerRemoving.
--
-- Usage (server, in a service's Start()):
--   RateLimit.connect("BuyTool", function(player, toolIndex)
--       if typeof(toolIndex) ~= "number" then return end -- validate every argument next
--       ...
--   end)
-- or, if you connect the RemoteEvent yourself: `if not RateLimit.check(player, "BuyTool") then return end`
-- as the very first line of the handler.
--
-- `newBucket` and `take` are pure (time is passed in), so qa can unit-test the bucket math without players.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Remotes = require(script.Parent.Remotes)

export type Bucket = {
	tokens: number,
	last: number, -- clock time of the last refill
}

local RateLimit = {}

-- Pure helpers ---------------------------------------------------------------------------------------

-- A fresh bucket starts full.
function RateLimit.newBucket(burst: number, now: number): Bucket
	return { tokens = burst, last = now }
end

-- Refills `bucket` for the time since its last call, then takes one token if available.
-- Returns true if the call is allowed. Mutates `bucket`. A clock that goes backwards refills nothing.
function RateLimit.take(bucket: Bucket, rate: number, burst: number, now: number): boolean
	local elapsed = now - bucket.last
	if elapsed > 0 then
		bucket.tokens = math.min(burst, bucket.tokens + elapsed * rate)
	end
	bucket.last = now
	if bucket.tokens >= 1 then
		bucket.tokens -= 1
		return true
	end
	return false
end

-- Per-player state -----------------------------------------------------------------------------------

local buckets: { [Player]: { [string]: Bucket } } = {}

-- Returns true if `player` may make one more call to remote `name` right now (and consumes a token).
-- False for over-limit calls, for players who already left, and (with a warning) for remotes that have no
-- rate/burst, which means a C->S remote is missing its limit in Contracts/Remotes.luau.
function RateLimit.check(player: Player, name: Remotes.RemoteName): boolean
	if player.Parent ~= Players then
		return false -- left (or leaving): never recreate state after PlayerRemoving
	end
	local def = Remotes.Definitions[name]
	local rate, burst = def and def.rate, def and def.burst
	if rate == nil or burst == nil then
		warn(`RateLimit: remote "{name}" has no rate/burst in Contracts/Remotes.luau; call dropped`)
		return false
	end
	local now = os.clock()
	local perPlayer = buckets[player]
	if perPlayer == nil then
		perPlayer = {}
		buckets[player] = perPlayer
	end
	local bucket = perPlayer[name]
	if bucket == nil then
		bucket = RateLimit.newBucket(burst, now)
		perPlayer[name] = bucket
	end
	return RateLimit.take(bucket, rate, burst, now)
end

-- Drops all of a player's buckets. Called automatically on PlayerRemoving (server).
function RateLimit.clear(player: Player)
	buckets[player] = nil
end

-- Server only: connects `handler` to C->S remote `name`, behind the rate limit. Over-limit calls never reach
-- the handler. The handler still has to validate every argument (architecture.md section 2 handler rules).
function RateLimit.connect(
	name: Remotes.RemoteName,
	handler: (player: Player, ...any) -> ()
): RBXScriptConnection
	assert(RunService:IsServer(), "RateLimit.connect must run on the server")
	local def = Remotes.Definitions[name]
	assert(def and def.direction == "C2S", `RateLimit.connect: "{name}" is not a C->S remote`)
	return Remotes.getEvent(name).OnServerEvent:Connect(function(player: Player, ...: any)
		if RateLimit.check(player, name) then
			handler(player, ...)
		end
	end)
end

if RunService:IsServer() then
	Players.PlayerRemoving:Connect(RateLimit.clear)
end

return RateLimit
