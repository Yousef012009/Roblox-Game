--!strict
--[[
	WordRules  (ModuleScript)  ·  ReplicatedStorage/Shared/WordRules

	Answer cleaning, validation and the "no repeats" key.

	  • The CLIENT calls `validate` before sending, so a typo like an empty
	    answer gets instant feedback without a network round trip.
	  • The SERVER calls the same functions again and is the only one whose
	    result counts.

	Repeat detection compares `canonicalKey`s, so these all collide:
	    "Ice Cream" · "ice-cream" · "ICE  CREAM!" · "the ice creams"
]]

local Config = require(script.Parent.Config)

local WordRules = {}

-- Cut a string to at most `maxChars` characters without splitting a
-- multi-byte UTF-8 character.
function WordRules.truncate(text: string, maxChars: number): string
	local length = utf8.len(text)
	if length == nil then
		return "" -- invalid UTF-8: reject it outright
	end
	if length <= maxChars then
		return text
	end
	local cutAt = utf8.offset(text, maxChars + 1)
	return if cutAt then string.sub(text, 1, cutAt - 1) else text
end

-- Trim, collapse whitespace and strip control characters. Keeps the player's
-- capitalisation, because this is the version that gets displayed.
function WordRules.clean(text: string): string
	local cleaned = string.gsub(text, "%c", " ")
	cleaned = string.gsub(cleaned, "%s+", " ")
	return string.match(cleaned, "^%s*(.-)%s*$") or ""
end

-- Lower-case, drop ASCII punctuation, single spaces. Non-ASCII letters (é, ñ,
-- кот) are kept as they are.
function WordRules.normalize(text: string): string
	local lowered = string.lower(WordRules.clean(text))
	lowered = string.gsub(lowered, "%p", "")
	lowered = string.gsub(lowered, "%s+", " ")
	return string.match(lowered, "^%s*(.-)%s*$") or ""
end

-- Cheap English singular: "berries"→"berry", "boxes"→"box", "cats"→"cat".
-- It does not need to be perfect, only consistent, because both words go
-- through the same function.
local function singular(word: string): string
	local n = #word
	if n > 4 and string.sub(word, -3) == "ies" then
		return string.sub(word, 1, -4) .. "y"
	end
	if n > 4 then
		local tail4 = string.sub(word, -4)
		if tail4 == "ches" or tail4 == "shes" or tail4 == "sses" then
			return string.sub(word, 1, -3)
		end
		local tail3 = string.sub(word, -3)
		if tail3 == "xes" or tail3 == "zes" then
			return string.sub(word, 1, -3)
		end
	end
	if n > 3 and string.sub(word, -1) == "s" then
		local tail2 = string.sub(word, -2)
		if tail2 ~= "ss" and tail2 ~= "us" and tail2 ~= "is" then
			return string.sub(word, 1, -2)
		end
	end
	return word
end

-- The "no repeats" key. Two answers repeat each other if their keys match.
function WordRules.canonicalKey(text: string): string
	local words = string.split(WordRules.normalize(text), " ")

	if Config.Words.IgnoreLeadingArticles and #words > 1 then
		local first = words[1]
		if first == "the" or first == "a" or first == "an" then
			table.remove(words, 1)
		end
	end

	if Config.Words.TreatPluralsAsRepeats and #words > 0 then
		words[#words] = singular(words[#words])
	end

	-- "ice cream" == "icecream"
	return table.concat(words, "")
end

-- Shared validator. Returns (true, cleanedText) or (false, reasonForPlayer).
function WordRules.validate(raw: string, minLength: number?, maxLength: number?): (boolean, string)
	local minLen = minLength or Config.Words.MinLength
	local maxLen = maxLength or Config.Words.MaxLength

	if utf8.len(raw) == nil then
		return false, "That text has characters we can't read."
	end

	local cleaned = WordRules.clean(raw)
	local length = utf8.len(cleaned) or 0
	if length < minLen then
		return false, if length == 0 then "Type something first!" else `At least {minLen} characters, detective.`
	end
	if length > maxLen then
		return false, `Keep it under {maxLen} characters.`
	end
	-- Must contain at least one letter or digit (ASCII or any non-ASCII byte).
	if not string.find(cleaned, "[%w\128-\255]") then
		return false, "Use real letters!"
	end
	if WordRules.canonicalKey(cleaned) == "" then
		return false, "That's not a real answer."
	end
	return true, cleaned
end

-- Same rules with the custom-category length limits.
function WordRules.validateCategory(raw: string): (boolean, string)
	return WordRules.validate(raw, Config.Category.CustomMinLength, Config.Category.CustomMaxLength)
end

return WordRules
