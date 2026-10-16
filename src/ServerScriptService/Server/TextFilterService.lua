--!strict
--[[
	TextFilterService  (ModuleScript)  ·  ServerScriptService/Server/TextFilterService

	Roblox requires ALL player-typed text that other players can see to go
	through TextService filtering. That covers answers, the live typing on the
	TV and custom categories. Skip this and the game can be moderated.

	Two entry points:
	  • forBroadcast(text, userId)     yields; one-off filter (answers, categories)
	  • submitDraft(player, text, cb)  live typing. Coalesces keystrokes so at
	    most ONE filter request per player is in flight, rate-limited by
	    Config.Typing.ServerMinInterval. Only the newest draft is ever filtered,
	    which keeps us well inside TextService's limits.

	Note: Studio does not filter (text comes back unchanged). Test filtering
	in a live server.
]]

local TextService = game:GetService("TextService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)

local TextFilterService = {}

-- Filter `text` typed by `fromUserId` for display to everyone in the server.
-- Returns (ok, filteredText). On failure you must NOT show the original.
function TextFilterService.forBroadcast(text: string, fromUserId: number): (boolean, string)
	if text == "" then
		return true, ""
	end

	local ok, result = pcall(function()
		return TextService:FilterStringAsync(text, fromUserId, Enum.TextFilterContext.PublicChat)
	end)
	if not ok then
		warn("[TextFilter] FilterStringAsync failed:", result)
		return false, ""
	end

	local ok2, filtered = pcall(function()
		return (result :: TextFilterResult):GetNonChatStringForBroadcastAsync()
	end)
	if not ok2 then
		warn("[TextFilter] GetNonChatStringForBroadcastAsync failed:", filtered)
		return false, ""
	end
	return true, filtered :: string
end

-- Roblox replaces filtered characters with '#'.
function TextFilterService.wasCensored(original: string, filtered: string): boolean
	local _, originalHashes = string.gsub(original, "#", "")
	local _, filteredHashes = string.gsub(filtered, "#", "")
	return filteredHashes > originalHashes
end

----------------------------------------------------------------------------
-- Live-typing drafts
----------------------------------------------------------------------------
type DraftState = {
	busy: boolean,
	pending: string?,
	lastFiltered: string?,
	lastAt: number,
	callback: ((string) -> ())?,
}

local drafts: { [Player]: DraftState } = setmetatable({}, { __mode = "k" }) :: any

-- Queue `text` for filtering. `callback(filtered)` runs with the newest
-- filtered draft. Older drafts that were still waiting are dropped.
function TextFilterService.submitDraft(player: Player, text: string, callback: (string) -> ())
	local state = drafts[player]
	if not state then
		state = { busy = false, lastAt = 0 }
		drafts[player] = state
	end
	state.pending = text
	state.callback = callback

	if state.busy then
		return -- the running worker will pick up `pending`
	end
	state.busy = true

	task.spawn(function()
		while state.pending ~= nil and player.Parent ~= nil do
			local waitFor = Config.Typing.ServerMinInterval - (os.clock() - state.lastAt)
			if waitFor > 0 then
				task.wait(waitFor)
			end

			local draft = state.pending :: string
			state.pending = nil
			if draft ~= state.lastFiltered then
				state.lastAt = os.clock()
				local ok, filtered = TextFilterService.forBroadcast(draft, player.UserId)
				state.lastFiltered = draft
				local cb = state.callback
				if ok and cb then
					cb(filtered)
				end
			end
		end
		state.busy = false
	end)
end

-- Reset draft state (call at the start of each turn).
function TextFilterService.resetDraft(player: Player)
	local state = drafts[player]
	if state then
		state.pending = nil
		state.lastFiltered = nil
		state.callback = nil
	end
end

return TextFilterService
