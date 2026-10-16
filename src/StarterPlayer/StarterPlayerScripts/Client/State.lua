--!strict
--[[
	State  (ModuleScript)  ·  StarterPlayerScripts/Client/State

	The client's mirror of what the server told it. ClientManager is the only
	writer; every screen reads it. All lookups are nil-safe: a snapshot field
	missing or a player that left never raises.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Remotes = require(ReplicatedStorage.Shared.Remotes)

export type Snapshot = Remotes.MatchSnapshot
export type MatchPlayer = Remotes.MatchPlayer
export type QueueStatus = Remotes.QueueStatus

local State = {
	localUserId = Players.LocalPlayer.UserId,
	queues = {} :: { [number]: QueueStatus }, -- by queue index
	queueIndex = nil :: number?,
	snapshot = nil :: Snapshot?,
	playersById = {} :: { [number]: MatchPlayer },
	me = nil :: MatchPlayer?,
	room = nil :: Model?, -- resolved Workspace.ActiveMatches[roomName], may stay nil
	typing = false, -- a local TextBox (answer / category) has focus
}

function State.now(): number
	return Workspace:GetServerTimeNow()
end

-- Rebuilds the derived lookups after a new snapshot arrives.
function State.setSnapshot(snapshot: Snapshot?)
	State.snapshot = snapshot
	table.clear(State.playersById)
	State.me = nil
	if not snapshot then
		return
	end
	local list: { MatchPlayer } = if type(snapshot.players) == "table" then snapshot.players else {}
	for _, player in list do
		State.playersById[player.userId] = player
		if player.userId == State.localUserId then
			State.me = player
		end
	end
end

function State.matchId(): string?
	local snapshot = State.snapshot
	return if snapshot then snapshot.matchId else nil
end

function State.stateName(): string?
	local snapshot = State.snapshot
	return if snapshot then snapshot.state else nil
end

function State.nameOf(userId: number?): string
	if userId == nil then
		return "?"
	end
	local player = State.playersById[userId]
	if player then
		return player.name
	end
	local live = Players:GetPlayerByUserId(userId)
	return if live then live.DisplayName else "UNKNOWN"
end

-- AI detectives have negative userIds and no Player; trust the flag first.
function State.isBot(userId: number?): boolean
	if userId == nil then
		return false
	end
	local player = State.playersById[userId]
	if player then
		return player.isBot == true
	end
	return userId < 0
end

-- Upper-case display name with an "(AI)" tag for bots (plain text).
function State.tagName(userId: number?): string
	local name = string.upper(State.nameOf(userId))
	return if State.isBot(userId) then `{name} (AI)` else name
end

-- Number of participants still in play (status Active).
function State.activeCount(): number
	local snapshot = State.snapshot
	local count = 0
	if snapshot and type(snapshot.players) == "table" then
		for _, player in snapshot.players do
			if player.status == "Active" then
				count += 1
			end
		end
	end
	return count
end

function State.isCaller(): boolean
	local snapshot = State.snapshot
	return snapshot ~= nil and snapshot.callerUserId == State.localUserId
end

-- Eliminated (or flagged Left) players watch from behind the mirror.
function State.isSpectator(): boolean
	local me = State.me
	return me ~= nil and me.status ~= "Active"
end

function State.isMyTurn(): boolean
	local snapshot = State.snapshot
	if not snapshot or snapshot.state ~= "PLAYING" then
		return false
	end
	local turn = snapshot.turn
	return turn ~= nil and turn.userId == State.localUserId
end

-- True while the local player is seated in a live (not ending) match.
function State.inLiveMatch(): boolean
	local snapshot = State.snapshot
	return snapshot ~= nil and snapshot.state ~= "CLEANUP"
end

return State
