--!strict
--[[
	MatchService  (ModuleScript)  ·  ServerScriptService/Server/MatchService

	Owns the pool of room slots and the player -> match map.

	  • Slots 0 .. Config.Match.MaxConcurrentMatches-1. Slot 0 sits at
	    Config.Match.RoomOrigin, slot k ≥ 1 is offset along Z by
	    RoomSpacing * ceil(k/2), alternating + (odd k) and - (even k).
	  • QueueService reserves a slot when a queue starts departing
	    (reserveSlot) and hands the reservation to startMatch, so two queues
	    departing in the same scan can never race for the last room.
	  • startMatch(humans, botCount, ...) clones ServerStorage.
	    InterrogationModuleTemplate, names it Match_<slot>, tags it (MatchId,
	    Slot), pivots it into place BEFORE parenting it to
	    Workspace.ActiveMatches, makes it PersistentPerPlayer for its humans
	    and starts a Match with `botCount` AI detectives (negative userIds,
	    unique for the server's lifetime; Config.Bots.Enabled = false or a
	    full room means fewer / none).
	  • Remote input is type-checked here, then routed to the sender's match
	    only if the matchId the client echoed is that match's id.
]]

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local Shared = ReplicatedStorage.Shared
local Config = require(Shared.Config)
local Names = require(Shared.Names)
local Remotes = require(Shared.Remotes)

local Match = require(script.Parent.Match)

local MAX_ID_BYTES = 64 -- match ids are GUIDs (36 chars); anything longer is junk
local MAX_TURN_ID = 2 ^ 31

type MatchServiceData = {
	map: Instance,
	activeFolder: Instance,
	slots: { [number]: Match.Match },
	reserved: { [number]: boolean },
	playerMatch: { [Player]: Match.Match },
	nextBotId: number, -- counts down: -1, -2, ...
	rng: Random,
	warnedNoLobby: boolean,
}

local MatchService = {}
MatchService.__index = MatchService

export type MatchService = typeof(setmetatable({} :: MatchServiceData, MatchService))

----------------------------------------------------------------------------
-- Argument validation for client -> server input
----------------------------------------------------------------------------

local function asMatchId(value: unknown): string?
	if type(value) == "string" and #value > 0 and #value <= MAX_ID_BYTES then
		return value
	end
	return nil
end

local function asTurnId(value: unknown): number?
	-- Rejects NaN (value ~= value), infinities and fractions (x % 1 is NaN or non-zero).
	if type(value) == "number" and value == value and value % 1 == 0 and value >= 0 and value < MAX_TURN_ID then
		return value
	end
	return nil
end

local function asText(value: unknown): string?
	if type(value) == "string" and #value <= Config.Text.RawMaxBytes then
		return value
	end
	return nil
end

local function asVerdict(value: unknown): Match.Verdict?
	if value == "Valid" or value == "Wrong" then
		return value :: Match.Verdict
	end
	return nil
end

----------------------------------------------------------------------------
-- Construction / slots
----------------------------------------------------------------------------

function MatchService.new(map: Instance, activeFolder: Instance): MatchService
	local self: MatchServiceData = {
		map = map,
		activeFolder = activeFolder,
		slots = {},
		reserved = {},
		playerMatch = {},
		nextBotId = 0,
		rng = Random.new(),
		warnedNoLobby = false,
	}
	return setmetatable(self, MatchService)
end

-- World position of slot `slot` (0-based).
function MatchService.slotPosition(slot: number): Vector3
	local origin = Config.Match.RoomOrigin
	if slot <= 0 then
		return origin
	end
	local direction = if slot % 2 == 1 then 1 else -1
	return origin + Vector3.new(0, 0, Config.Match.RoomSpacing * math.ceil(slot / 2) * direction)
end

function MatchService.isSlotFree(self: MatchService, slot: number): boolean
	return not self.slots[slot] and not self.reserved[slot]
end

function MatchService.firstFreeSlot(self: MatchService): number?
	for slot = 0, Config.Match.MaxConcurrentMatches - 1 do
		if self:isSlotFree(slot) then
			return slot
		end
	end
	return nil
end

function MatchService.hasFreeSlot(self: MatchService): boolean
	return self:firstFreeSlot() ~= nil
end

-- Holds a slot for a departing queue. Pass it to startMatch (which consumes
-- it) or give it back with releaseReservation.
function MatchService.reserveSlot(self: MatchService): number?
	local slot = self:firstFreeSlot()
	if slot ~= nil then
		self.reserved[slot] = true
	end
	return slot
end

function MatchService.releaseReservation(self: MatchService, slot: number)
	self.reserved[slot] = nil
end

function MatchService.activeMatchCount(self: MatchService): number
	local count = 0
	for _ in self.slots do
		count += 1
	end
	return count
end

----------------------------------------------------------------------------
-- Membership
----------------------------------------------------------------------------

function MatchService.matchOf(self: MatchService, player: Player): Match.Match?
	return self.playerMatch[player]
end

function MatchService.isInMatch(self: MatchService, player: Player): boolean
	return if self.playerMatch[player] then true else false
end

function MatchService.snapshotFor(self: MatchService, player: Player): Remotes.MatchSnapshot?
	local match = self.playerMatch[player]
	return if match then match:snapshotFor(player) else nil
end

-- Called by a Match when it lets a player go (never loaded, or CLEANUP).
function MatchService.releasePlayer(self: MatchService, player: Player, match: Match.Match)
	if self.playerMatch[player] == match then
		self.playerMatch[player] = nil
	end
end

-- Called by a Match as the very last step of its cleanup.
function MatchService.onMatchClosed(self: MatchService, match: Match.Match, slot: number)
	if self.slots[slot] == match then
		self.slots[slot] = nil
	end
	for player, owner in self.playerMatch do
		if owner == match then
			self.playerMatch[player] = nil
		end
	end
	if Config.Debug.Verbose then
		print(`[MatchService] slot {slot} free ({self:activeMatchCount()} active)`)
	end
end

function MatchService.onPlayerRemoving(self: MatchService, player: Player)
	local match = self.playerMatch[player]
	self.playerMatch[player] = nil
	if match then
		match:onPlayerLeft(player)
	end
end

----------------------------------------------------------------------------
-- Lobby return points
----------------------------------------------------------------------------

-- `count` landing CFrames in the lobby, spread over LobbyReturnPoints
-- (shuffled; fanned out sideways when there are more players than points),
-- falling back to positions around LobbySpawn. Empty if neither exists.
function MatchService.lobbyTargets(self: MatchService, count: number): { CFrame }
	local targets: { CFrame } = table.create(count)
	local lobby = self.map:FindFirstChild(Names.Lobby)

	local points: { BasePart } = {}
	local folder = if lobby then lobby:FindFirstChild(Names.LobbyReturnPoints) else nil
	if folder then
		for _, child in folder:GetChildren() do
			if child:IsA("BasePart") then
				table.insert(points, child)
			end
		end
	end
	if #points > 0 then
		for index = #points, 2, -1 do
			local swap = self.rng:NextInteger(1, index)
			points[index], points[swap] = points[swap], points[index]
		end
		for index = 1, count do
			local point = points[(index - 1) % #points + 1]
			local lap = (index - 1) // #points
			targets[index] = point.CFrame + Vector3.new(lap * 3, 0, 0)
		end
		return targets
	end

	local spawnPart = if lobby then lobby:FindFirstChild(Names.LobbySpawn, true) else nil
	if spawnPart and spawnPart:IsA("BasePart") then
		for index = 1, count do
			local offset = ((index - 1) % 4 - 1.5) * 3
			targets[index] = spawnPart.CFrame + Vector3.new(offset, 0, 0)
		end
		return targets
	end

	if not self.warnedNoLobby then
		self.warnedNoLobby = true
		warn(`[MatchService] no {Names.LobbyReturnPoints} or {Names.LobbySpawn} found; players will respawn instead`)
	end
	return targets
end

----------------------------------------------------------------------------
-- Starting a match
----------------------------------------------------------------------------

local function cloneRoom(self: MatchService, slot: number, matchId: string, roster: { Player }): Model?
	local template = ServerStorage:FindFirstChild(Names.Template)
	if not template or not template:IsA("Model") then
		warn(`[MatchService] ServerStorage.{Names.Template} (Model) is missing; cannot start a match`)
		return nil
	end
	local roomName = Names.MatchRoomPrefix .. tostring(slot)
	local stale = self.activeFolder:FindFirstChild(roomName)
	if stale then
		warn(`[MatchService] removing stale room {roomName}`)
		stale:Destroy()
	end

	local room = template:Clone() :: Model?
	if not room then
		warn(`[MatchService] {Names.Template} could not be cloned (Archivable = false?)`)
		return nil
	end
	room.Name = roomName
	room:SetAttribute(Names.AttrMatchId, matchId)
	room:SetAttribute(Names.AttrSlot, slot)
	-- Position BEFORE parenting so the room never replicates at the template's spot.
	room:PivotTo(CFrame.new(MatchService.slotPosition(slot)))
	room.ModelStreamingMode = Enum.ModelStreamingMode.PersistentPerPlayer
	room.Parent = self.activeFolder
	for _, player in roster do
		room:AddPersistentPlayer(player)
	end
	return room
end

-- Starts a match for `humans` plus `botCount` AI detectives (the Match
-- shuffles them around the table). `reservedSlot` (from reserveSlot) is
-- consumed whatever happens. Never yields. Returns nil if no slot /
-- template / eligible human is available.
function MatchService.startMatch(
	self: MatchService,
	humans: { Player },
	botCount: number,
	queueIndex: number,
	reservedSlot: number?
): Match.Match?
	if reservedSlot ~= nil then
		self.reserved[reservedSlot] = nil
	end
	local slot = if reservedSlot ~= nil and not self.slots[reservedSlot] then reservedSlot else self:firstFreeSlot()
	if slot == nil then
		warn("[MatchService] no free room slot")
		return nil
	end

	local capacity = Config.Queue.Capacity
	local roster: { Player } = {}
	for _, player in humans do
		if
			#roster < capacity
			and player.Parent == Players
			and not self.playerMatch[player]
			and not table.find(roster, player)
		then
			table.insert(roster, player)
		end
	end
	if #roster == 0 then
		return nil
	end

	local wantedBots = if Config.Bots.Enabled and botCount == botCount then math.floor(botCount) else 0
	local bots = math.clamp(wantedBots, 0, capacity - #roster)
	local botIds: { number } = table.create(bots)
	for index = 1, bots do
		self.nextBotId -= 1
		botIds[index] = self.nextBotId
	end

	local matchId = HttpService:GenerateGUID(false)
	local room = cloneRoom(self, slot, matchId, roster)
	if not room then
		return nil
	end

	local match: Match.Match
	match = Match.new({
		id = matchId,
		slot = slot,
		queueIndex = queueIndex,
		room = room,
		players = roster,
		botIds = botIds,
		releasePlayer = function(player: Player)
			self:releasePlayer(player, match)
		end,
		onClosed = function()
			self:onMatchClosed(match, slot)
		end,
		lobbyTargets = function(count: number): { CFrame }
			return self:lobbyTargets(count)
		end,
	})
	self.slots[slot] = match
	for _, player in roster do
		self.playerMatch[player] = match
	end
	if Config.Debug.Verbose then
		print(`[MatchService] match {matchId} in {room.Name} from queue {queueIndex}: {#roster} humans + {bots} bots`)
	end
	match:start()
	return match
end

----------------------------------------------------------------------------
-- Remote routing (GameManager rate-limits first)
----------------------------------------------------------------------------

-- The sender's match, only if the matchId they echoed is that match's id.
function MatchService.route(self: MatchService, player: Player, matchId: string): Match.Match?
	local match = self.playerMatch[player]
	if match and match.id == matchId and not match:isClosed() then
		return match
	end
	return nil
end

function MatchService.onSubmitCategory(self: MatchService, player: Player, matchId: unknown, text: unknown)
	local id = asMatchId(matchId)
	local body = asText(text)
	if not id or not body then
		return
	end
	local match = self:route(player, id)
	if match then
		match:submitCategory(player, body)
	end
end

function MatchService.onSubmitAnswer(self: MatchService, player: Player, matchId: unknown, turnId: unknown, text: unknown)
	local id = asMatchId(matchId)
	local turn = asTurnId(turnId)
	local body = asText(text)
	if not id or not turn or not body then
		return
	end
	local match = self:route(player, id)
	if match then
		match:submitAnswer(player, turn, body)
	end
end

function MatchService.onJudgeAnswer(self: MatchService, player: Player, matchId: unknown, turnId: unknown, verdict: unknown)
	local id = asMatchId(matchId)
	local turn = asTurnId(turnId)
	local decision: Match.Verdict? = asVerdict(verdict)
	if not id or not turn or not decision then
		return
	end
	local match = self:route(player, id)
	if match then
		match:judgeAnswer(player, turn, decision)
	end
end

return MatchService
