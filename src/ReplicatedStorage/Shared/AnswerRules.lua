--!strict
--[[
	AnswerRules  (ModuleScript)  ·  ReplicatedStorage/Shared/AnswerRules

	Cleaning, length validation and the repeat-detection key.

	Deliberately CONSERVATIVE normalization. Only differences that cannot
	change meaning are erased:
	    case                "APPLE"  == "apple"
	    outer whitespace    " apple" == "apple"
	    repeated spaces     "ice  cream" == "ice cream"
	    punctuation         "apple!" == "apple",  "t-rex" == "trex"
	Plurals, articles, spelling variants and synonyms are NOT merged.
	"Cat" and "Cats" are different answers; that is the Caller's call.

	The client calls `validate` for instant feedback; the server re-runs it
	and its result is the only one that counts.
]]

local Config = require(script.Parent.Config)

local AnswerRules = {}

-- Cut to at most `maxChars` characters without splitting a UTF-8 character.
-- Invalid UTF-8 returns "".
function AnswerRules.truncate(text: string, maxChars: number): string
	local length = utf8.len(text)
	if length == nil then
		return ""
	end
	if length <= maxChars then
		return text
	end
	local cutAt = utf8.offset(text, maxChars + 1)
	return if cutAt then string.sub(text, 1, cutAt - 1) else text
end

-- Trim, collapse whitespace, remove control characters. Keeps capitalisation
-- (this is the version that gets displayed after filtering).
function AnswerRules.clean(text: string): string
	local cleaned = string.gsub(text, "%c", " ")
	cleaned = string.gsub(cleaned, "%s+", " ")
	return string.match(cleaned, "^%s*(.-)%s*$") or ""
end

-- Repeat-detection key: lower-case, ASCII punctuation removed, single spaces.
function AnswerRules.key(text: string): string
	local lowered = string.lower(AnswerRules.clean(text))
	lowered = string.gsub(lowered, "%p", "")
	lowered = string.gsub(lowered, "%s+", " ")
	return string.match(lowered, "^%s*(.-)%s*$") or ""
end

local function validateLength(raw: string, minLen: number, maxLen: number, what: string): (boolean, string)
	if #raw > Config.Text.RawMaxBytes or utf8.len(raw) == nil then
		return false, `That {what} can't be read.`
	end
	local cleaned = AnswerRules.clean(raw)
	local length = utf8.len(cleaned) or 0
	if length == 0 then
		return false, `Type a {what} first.`
	end
	if length < minLen then
		return false, `The {what} needs at least {minLen} characters.`
	end
	if length > maxLen then
		return false, `Keep the {what} under {maxLen + 1} characters.`
	end
	-- Needs at least one letter or digit (ASCII, or any non-ASCII byte).
	if not string.find(cleaned, "[%w\128-\255]") then
		return false, `The {what} needs letters or numbers.`
	end
	return true, cleaned
end

-- Returns (true, cleanedAnswer) or (false, reasonForPlayer).
function AnswerRules.validateAnswer(raw: string): (boolean, string)
	local ok, result = validateLength(raw, Config.Text.AnswerMinLength, Config.Text.AnswerMaxLength, "answer")
	if ok and AnswerRules.key(result) == "" then
		return false, "The answer needs letters or numbers."
	end
	return ok, result
end

-- Returns (true, cleanedCategory) or (false, reasonForPlayer).
function AnswerRules.validateCategory(raw: string): (boolean, string)
	return validateLength(raw, Config.Text.CategoryMinLength, Config.Text.CategoryMaxLength, "category")
end

-- Roblox replaces filtered characters with '#'. True if filtering hid
-- anything the player typed.
function AnswerRules.wasCensored(original: string, filtered: string): boolean
	local _, before = string.gsub(original, "#", "")
	local _, after = string.gsub(filtered, "#", "")
	return after > before
end

return AnswerRules
