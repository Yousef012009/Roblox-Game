--!strict
--[[
	RateLimiter  (ModuleScript)  ·  ServerScriptService/Server/RateLimiter

	Token-bucket limiter for RemoteEvents, so an exploiter cannot fire a remote
	thousands of times a second.

	    local allowSubmit = RateLimiter.new(5, 5) -- 5 per second, bursts of 5
	    if not allowSubmit(player) then return end

	Buckets are weak-keyed, so players who leave are garbage-collected.
]]

local RateLimiter = {}

type Bucket = { tokens: number, last: number }

function RateLimiter.new(perSecond: number, burst: number): (Player) -> boolean
	local buckets: { [Player]: Bucket } = setmetatable({}, { __mode = "k" }) :: any

	return function(player: Player): boolean
		local now = os.clock()
		local bucket = buckets[player]
		if not bucket then
			bucket = { tokens = burst, last = now }
			buckets[player] = bucket
		end
		bucket.tokens = math.min(burst, bucket.tokens + (now - bucket.last) * perSecond)
		bucket.last = now
		if bucket.tokens < 1 then
			return false
		end
		bucket.tokens -= 1
		return true
	end
end

return RateLimiter
