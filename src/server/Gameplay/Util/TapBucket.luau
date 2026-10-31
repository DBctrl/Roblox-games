--!strict
-- Pure per-tap token bucket for TapService (architecture section 2 #1). Owned by gameplay-programmer.
-- Contracts/RateLimit limits messages per second; this limits taps per second inside those messages.
-- Time is passed in, so qa can test floods and clock jumps without players (T-025).

export type Bucket = {
	tokens: number,
	last: number,
}

local TapBucket = {}

function TapBucket.new(capacity: number, now: number): Bucket
	return { tokens = capacity, last = now }
end

-- Refills at `rate` taps/s up to `capacity`, then accepts up to `count` whole taps. Returns the number accepted
-- (0 when empty). A clock that goes backwards refills nothing; a lower rate trims stored tokens to the new cap.
function TapBucket.take(bucket: Bucket, count: number, rate: number, capacity: number, now: number): number
	local elapsed = now - bucket.last
	if elapsed > 0 then
		bucket.tokens += elapsed * rate
	end
	bucket.last = now
	bucket.tokens = math.clamp(bucket.tokens, 0, math.max(0, capacity))
	local accepted = math.clamp(math.floor(bucket.tokens), 0, math.max(0, math.floor(count)))
	bucket.tokens -= accepted
	return accepted
end

return TapBucket
