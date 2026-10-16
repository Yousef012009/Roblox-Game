--!strict
--[[
	TextFilter  (ModuleScript)  ·  ServerScriptService/Server/TextFilter

	Roblox text filtering for player-written text that every player in the
	server may see (categories on the TV, answers in the HUD and on the TV).

	    local ok, filteredOrError = TextFilter.forBroadcast(text, player.UserId)

	Uses TextService:FilterStringAsync with Enum.TextFilterContext.PublicChat
	and TextFilterResult:GetNonChatStringForBroadcastAsync(). Both calls yield
	and can throw (web request failures), so they run inside pcall with ONE
	retry after a short pause. Two failures in a row return false; the caller
	applies the game policy (answer: the turn is voided; category: a fallback
	category is used). Censorship is detected by the caller with
	AnswerRules.wasCensored(original, filtered).

	In Studio the filter returns the text unchanged, which is expected.
]]

local TextService = game:GetService("TextService")

local TextFilter = {}

local ATTEMPTS = 2
local RETRY_DELAY_SECONDS = 0.5

local function filterOnce(text: string, fromUserId: number): string
	local result = TextService:FilterStringAsync(text, fromUserId, Enum.TextFilterContext.PublicChat)
	return result:GetNonChatStringForBroadcastAsync()
end

-- Returns (true, filteredText) or (false, errorMessage) after two failed attempts.
function TextFilter.forBroadcast(text: string, fromUserId: number): (boolean, string)
	local lastError = "unknown error"
	for attempt = 1, ATTEMPTS do
		local ok, result = pcall(filterOnce, text, fromUserId)
		if ok and type(result) == "string" then
			return true, result
		end
		lastError = tostring(result)
		if attempt < ATTEMPTS then
			task.wait(RETRY_DELAY_SECONDS)
		end
	end
	warn(`[TextFilter] filtering failed {ATTEMPTS} times for user {fromUserId}: {lastError}`)
	return false, lastError
end

return TextFilter
