--!strict
--[[
	Remotes  (ModuleScript)  ·  ReplicatedStorage/Shared/Remotes

	The complete network contract. On the SERVER, requiring this module
	creates ReplicatedStorage.Remotes and every remote inside it (reusing any
	that already exist). On the CLIENT it waits for them. Nothing has to be
	created by hand in Studio.

	┌──────────────────┬──────┬──────────────────────────────────────────────┬────────────────────────────────────────────┐
	│ Remote           │ Dir  │ Arguments                                    │ Server-side validation                     │
	├──────────────────┼──────┼──────────────────────────────────────────────┼────────────────────────────────────────────┤
	│ QueueStatus      │ S→all│ ({QueueStatus})                              │ server-built                               │
	│ QueueMembership  │ S→1  │ (queueIndex: number?)                        │ server-built                               │
	│ MatchSnapshot    │ S→m  │ (MatchSnapshot)  m = that match's players    │ server-built; versioned per match          │
	│ MatchEvent       │ S→m  │ (MatchEvent)     one-shot FX / announcements │ server-built                               │
	│ InputRejected    │ S→1  │ (what: "Answer"|"Category", reason: string)  │ server-built                               │
	│ Notify           │ S→1/all (message: string, kind: "Info"|"Error")     │ server-built                               │
	│ SubmitCategory   │ C→S  │ (matchId: string, text: string)              │ sender is THIS match's Caller, state is     │
	│                  │      │                                              │ CATEGORY_SELECTION, length, filter          │
	│ SubmitAnswer     │ C→S  │ (matchId: string, turnId: number, text)      │ sender owns the CURRENT turn of THIS match, │
	│                  │      │                                              │ turnId matches, arrived ≤ deadline+grace,   │
	│                  │      │                                              │ one submission per turn, length, filter     │
	│ JudgeAnswer      │ C→S  │ (matchId: string, turnId: number,            │ sender is THIS match's Caller, state is     │
	│                  │      │  verdict: "Valid"|"Wrong")                   │ JUDGING for that turnId, first verdict wins │
	│ LeaveQueue       │ C→S  │ ()                                           │ sender is in a queue that is not departing  │
	│ GetState (RF)    │ C→S  │ () → ClientState                             │ returns only the caller's own data          │
	└──────────────────┴──────┴──────────────────────────────────────────────┴────────────────────────────────────────────┘

	Every C→S remote is type-checked and rate-limited (Config.RateLimit) on the
	server. Unknown, malformed, stale (old matchId / turnId) or out-of-turn
	requests are dropped silently.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

----------------------------------------------------------------------------
-- Payload types
----------------------------------------------------------------------------
export type QueueState = "Open" | "Starting" | "Departing" | "WaitingForRoom"

export type QueueStatus = {
	index: number,
	count: number,
	capacity: number,
	state: QueueState,
	startsAt: number?, -- server clock time the doors close (state "Starting")
}

export type MatchState =
	"INTRO"
	| "CALLER_SELECTION"
	| "CATEGORY_SELECTION"
	| "COUNTDOWN"
	| "PLAYING"
	| "JUDGING"
	| "ELIMINATION"
	| "ROUND_END"
	| "GAME_END"
	| "CLEANUP"

export type PlayerStatus = "Active" | "Eliminated" | "Left"
export type PlayerRole = "Caller" | "Answerer"

export type MatchPlayer = {
	userId: number,
	name: string, -- DisplayName
	seat: number, -- 1..4, clockwise from above (play passes to the LEFT = next seat)
	role: PlayerRole, -- this round
	status: PlayerStatus, -- this round ("Eliminated" players are in the spectator lounge)
	roundWins: number,
	acceptedCount: number, -- accepted answers this match (tie-breaker)
}

export type TurnInfo = {
	id: number, -- unique per match; echo it back in SubmitAnswer / JudgeAnswer
	userId: number,
	startsAt: number, -- server clock (always on a beat)
	endsAt: number, -- server clock deadline (always on a beat)
	startBeat: number, -- musical beat numbers (MusicTimeline) of the same moments
	endBeat: number,
}

export type JudgingInfo = {
	turnId: number,
	userId: number, -- who answered
	answer: string, -- FILTERED text
	deadline: number, -- server clock; after this Config.Judging.TimeoutPolicy applies
}

export type AcceptedAnswer = {
	answer: string, -- filtered, as displayed
	userId: number,
	name: string,
}

export type MatchSnapshot = {
	matchId: string,
	version: number, -- increases with every snapshot of this match; ignore older ones
	state: MatchState,
	stateEndsAt: number?, -- server clock time the current state is scheduled to end (if timed)
	roomName: string, -- Workspace.ActiveMatches[roomName]
	slot: number,
	round: number,
	totalRounds: number,
	players: { MatchPlayer }, -- sorted by seat
	callerUserId: number?,
	autoJudge: boolean, -- true when no Caller can judge (left / repeated timeouts)
	category: string?, -- filtered
	musicStartTime: number?, -- server clock time of song position 0; nil = no music
	turnOrder: { number }, -- answerer userIds this round, in turn order (left of the Caller first)
	turn: TurnInfo?, -- the open turn (PLAYING)
	judging: JudgingInfo?, -- the answer being judged (JUDGING)
	accepted: { AcceptedAnswer }, -- this round, oldest first
	roundWinnerUserId: number?, -- ROUND_END
	winnerUserIds: { number }?, -- GAME_END (more than one = shared win)
}

export type EliminationReason = "Rejected" | "Repeat" | "Hesitation" | "Left"

export type MatchEvent = {
	matchId: string,
	kind: "Eliminated" | "Accepted" | "JudgeTimeout" | "RoundWinner" | "Victory" | "Notice",
	userId: number?, -- Eliminated / Accepted / RoundWinner
	userIds: { number }?, -- Victory
	reason: EliminationReason?, -- Eliminated
	answer: string?, -- Eliminated (Rejected/Repeat) / Accepted: filtered text
	text: string?, -- Notice / JudgeTimeout: human-readable message
}

export type ClientState = {
	queues: { QueueStatus },
	queueIndex: number?, -- the queue this player stands in
	match: MatchSnapshot?, -- the match this player belongs to
}

----------------------------------------------------------------------------
-- Instance creation / lookup
----------------------------------------------------------------------------
local IS_SERVER = RunService:IsServer()

local function getFolder(): Instance
	if IS_SERVER then
		local folder = ReplicatedStorage:FindFirstChild("Remotes")
		if not folder then
			folder = Instance.new("Folder")
			folder.Name = "Remotes"
			folder.Parent = ReplicatedStorage
		end
		return folder :: Instance
	end
	return ReplicatedStorage:WaitForChild("Remotes")
end

local folder = getFolder()

local function get(name: string, className: string): any
	if IS_SERVER then
		local existing = folder:FindFirstChild(name)
		if existing then
			assert(existing:IsA(className), `ReplicatedStorage.Remotes.{name} must be a {className}`)
			return existing
		end
		local remote = Instance.new(className :: any)
		remote.Name = name
		remote.Parent = folder
		return remote
	end
	return folder:WaitForChild(name)
end

local Remotes = {
	-- Server → Client
	QueueStatus = get("QueueStatus", "RemoteEvent") :: RemoteEvent,
	QueueMembership = get("QueueMembership", "RemoteEvent") :: RemoteEvent,
	MatchSnapshot = get("MatchSnapshot", "RemoteEvent") :: RemoteEvent,
	MatchEvent = get("MatchEvent", "RemoteEvent") :: RemoteEvent,
	InputRejected = get("InputRejected", "RemoteEvent") :: RemoteEvent,
	Notify = get("Notify", "RemoteEvent") :: RemoteEvent,

	-- Client → Server
	SubmitCategory = get("SubmitCategory", "RemoteEvent") :: RemoteEvent,
	SubmitAnswer = get("SubmitAnswer", "RemoteEvent") :: RemoteEvent,
	JudgeAnswer = get("JudgeAnswer", "RemoteEvent") :: RemoteEvent,
	LeaveQueue = get("LeaveQueue", "RemoteEvent") :: RemoteEvent,

	-- Client → Server (request/response)
	GetState = get("GetState", "RemoteFunction") :: RemoteFunction,
}

return Remotes
