--!strict
--[[
	BotBrain  (ModuleScript)  ·  ServerScriptService/Server/BotBrain

	Pure decisions of an AI detective. No state, no yields, no instances:
	Match owns the bot threads (it re-checks match / state / turn after every
	wait) and feeds the result into the same validated input paths a human
	uses. All randomness comes from the match's Random.

	    BotBrain.pickCategory(rng)                          a WordBank case file name
	    BotBrain.chooseAnswer(rng, category, accepted, keys) answer text, or nil = hesitate
	    BotBrain.judge(rng, category, answer)               "Valid" | "Wrong"
	    BotBrain.answerWait(rng, now, startsAt, endsAt)     seconds to wait before answering
	    BotBrain.delayWithin(rng, range, now, deadline)     seconds to wait before acting

	ANSWERING (Config.Bots)
	  HesitateChance              freeze: no answer at all (Hesitation)
	  RepeatChance                if answers were accepted: repeat one (Repeat)
	  WrongChance / unknown topic a plain noun from WordBank.Generic (the
	                              Caller should reject it)
	  otherwise                   an answer from the topic's bank nobody gave yet
	                              (bank exhausted: a plain noun)
	JUDGING (bot Caller)
	  Valid when AnswerRules.key(answer) is in the category's bank; otherwise
	  Valid with JudgeAcceptUnknownChance, else Wrong.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local AnswerRules = require(Shared.AnswerRules)
local Config = require(Shared.Config)
local Remotes = require(Shared.Remotes)

local WordBank = require(script.Parent.WordBank)

export type Verdict = "Valid" | "Wrong"

local BotBrain = {}

BotBrain.SafetyMargin = 0.6 -- a bot always finishes this long before a deadline

-- Uniform number in Config range {min, max} (tolerates a reversed or short table).
function BotBrain.inRange(rng: Random, range: { number }): number
	local low = range[1] or 0
	local high = range[2] or low
	if high < low then
		low, high = high, low
	end
	return rng:NextNumber(low, high)
end

-- Seconds to wait from `now` so the action lands `range` after now, but
-- never later than SafetyMargin before `deadline` (0 when already late).
function BotBrain.delayWithin(rng: Random, range: { number }, now: number, deadline: number): number
	local target = math.min(now + BotBrain.inRange(rng, range), deadline - BotBrain.SafetyMargin)
	return math.max(target - now, 0)
end

-- Seconds to wait from `now` before answering a turn that opens at
-- `startsAt` and closes at `endsAt` (Config.Bots.AnswerDelay after the open).
function BotBrain.answerWait(rng: Random, now: number, startsAt: number, endsAt: number): number
	local target = math.min(startsAt + BotBrain.inRange(rng, Config.Bots.AnswerDelay), endsAt - BotBrain.SafetyMargin)
	return math.max(target - now, 0)
end

function BotBrain.pickCategory(rng: Random): string
	return WordBank.random(rng).name
end

-- A random entry of `list` whose repeat key is not in `avoid` (nil if none).
local function pickFresh(rng: Random, list: { string }, avoid: { [string]: string }, alsoAvoid: WordBank.Category?): string?
	local count = #list
	if count == 0 then
		return nil
	end
	-- Start at a random index and walk the list once: uniform enough, allocation-free.
	local start = rng:NextInteger(1, count)
	for offset = 0, count - 1 do
		local candidate = list[(start - 1 + offset) % count + 1]
		if avoid[AnswerRules.key(candidate)] == nil and not (alsoAvoid and WordBank.knows(alsoAvoid, candidate)) then
			return candidate
		end
	end
	return nil
end

-- A plain noun that is neither accepted already nor (when known) on topic.
local function genericNoun(rng: Random, acceptedKeys: { [string]: string }, topic: WordBank.Category?): string
	return pickFresh(rng, WordBank.Generic, acceptedKeys, topic)
		or pickFresh(rng, WordBank.Generic, acceptedKeys, nil)
		or WordBank.Generic[rng:NextInteger(1, #WordBank.Generic)]
end

-- What a bot says on its turn. nil = it hesitates (says nothing).
function BotBrain.chooseAnswer(
	rng: Random,
	category: string?,
	accepted: { Remotes.AcceptedAnswer },
	acceptedKeys: { [string]: string }
): string?
	local bots = Config.Bots
	if rng:NextNumber() < bots.HesitateChance then
		return nil
	end
	if #accepted > 0 and rng:NextNumber() < bots.RepeatChance then
		return accepted[rng:NextInteger(1, #accepted)].answer
	end
	local topic = if category then WordBank.lookup(category) else nil
	if not topic or rng:NextNumber() < bots.WrongChance then
		return genericNoun(rng, acceptedKeys, topic)
	end
	return pickFresh(rng, topic.answers, acceptedKeys, nil) or genericNoun(rng, acceptedKeys, topic)
end

-- A bot Caller's ruling on `answer` in `category`.
function BotBrain.judge(rng: Random, category: string?, answer: string): Verdict
	local topic = if category then WordBank.lookup(category) else nil
	if topic and WordBank.knows(topic, answer) then
		return "Valid"
	end
	if rng:NextNumber() < Config.Bots.JudgeAcceptUnknownChance then
		return "Valid"
	end
	return "Wrong"
end

return BotBrain
