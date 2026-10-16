--!strict
--[[
	RateLimiter  (ModuleScript)  ·  ServerScriptService/Server/RateLimiter

	Token bucket per player per remote. Every (player, key) pair owns a bucket
	that holds at most `burst` tokens and refills continuously at `perSecond`
	tokens per second. A request spends one token; an empty bucket means the
	request is dropped.

	    local limiter = RateLimiter.new(Config.RateLimit.PerSecond, Config.RateLimit.Burst)
	    if not limiter:allow(player, "SubmitAnswer") then return end

	The outer table is weak-keyed on the Player, so a player who leaves never
	pins memory even if forget() is not called (GameManager calls it anyway on
	PlayerRemoving). os.clock() is used because it is monotonic and cheap;
	rate limiting does not need the shared server clock.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)

type Bucket = {
	tokens: number,
	updatedAt: number,
}

type RateLimiterData = {
	perSecond: number,
	burst: number,
	buckets: { [Player]: { [string]: Bucket } },
}

local RateLimiter = {}
RateLimiter.__index = RateLimiter

export type RateLimiter = typeof(setmetatable({} :: RateLimiterData, RateLimiter))

function RateLimiter.new(perSecond: number?, burst: number?): RateLimiter
	local rate = math.max(perSecond or Config.RateLimit.PerSecond, 0.01)
	local capacity = math.max(burst or Config.RateLimit.Burst, 1)
	local buckets: { [Player]: { [string]: Bucket } } = setmetatable({}, { __mode = "k" }) :: any
	local self: RateLimiterData = {
		perSecond = rate,
		burst = capacity,
		buckets = buckets,
	}
	return setmetatable(self, RateLimiter)
end

-- Spends one token from (player, key). Returns false when the bucket is empty.
function RateLimiter.allow(self: RateLimiter, player: Player, key: string): boolean
	local now = os.clock()
	local perPlayer = self.buckets[player]
	if not perPlayer then
		perPlayer = {}
		self.buckets[player] = perPlayer
	end
	local bucket = perPlayer[key]
	if not bucket then
		bucket = { tokens = self.burst, updatedAt = now }
		perPlayer[key] = bucket
	end

	-- Refill for the time elapsed since the last request, capped at the burst size.
	bucket.tokens = math.min(self.burst, bucket.tokens + (now - bucket.updatedAt) * self.perSecond)
	bucket.updatedAt = now

	if bucket.tokens < 1 then
		return false
	end
	bucket.tokens -= 1
	return true
end

-- Drops every bucket of a player (call on PlayerRemoving).
function RateLimiter.forget(self: RateLimiter, player: Player)
	self.buckets[player] = nil
end

return RateLimiter
