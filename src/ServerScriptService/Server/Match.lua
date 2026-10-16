--!strict
--[[
	Match  (ModuleScript)  ·  ServerScriptService/Server/Match

	ONE match: its players, its cloned room and its rounds. Every piece of
	mutable state lives on the instance (no module-level round variables),
	so any number of matches run side by side. Created by MatchService.

	STATE MACHINE  (Remotes.MatchState, docs/ARCHITECTURE.md §4)

	  (load: stream the room, wait for characters, seat everyone, lock movement)
	  INTRO ──IntroSeconds──► CALLER_SELECTION ──CallerRevealSeconds──► CATEGORY_SELECTION
	  CATEGORY_SELECTION ──category set (submitted · timeout · Caller left · filter down)──► COUNTDOWN
	  COUNTDOWN ──song reaches MusicTimeline.LoopStartBeat──► PLAYING
	  PLAYING ──answer, manual judging──► JUDGING ──Valid · judge timeout · Caller left──► PLAYING
	     │                                    └──Wrong──► ELIMINATION (Rejected)
	     ├──answer, auto-judge──► PLAYING (next turn)
	     ├──repeat of an accepted answer──► ELIMINATION (Repeat)
	     ├──deadline + latency grace passed──► ELIMINATION (Hesitation)
	     ├──answerer left──► ELIMINATION (Left)
	     └──at most one active answerer──► ROUND_END
	  ELIMINATION ──EliminationSeconds──► PLAYING (≥ 2 active answerers) | ROUND_END
	  ROUND_END ──more rounds and enough players──► CALLER_SELECTION | GAME_END
	  GAME_END ──GameEndSeconds──► CLEANUP (lobby, destroy room, free slot)
	  any ──connected < MinPlayersToContinue──► GAME_END   (nobody connected ► CLEANUP)

	CONCURRENCY
	  One coroutine (Match:run) owns the state and polls every LOOP_TICK.
	  Remote handlers only validate and RECORD input (turn.result,
	  judging.verdict, pendingCategory); the loop consumes it. A handler that
	  yields (text filter) first sets a "submitting" flag, which holds the
	  deadline, and after the yield re-checks that the match / state / turn /
	  round it started with is still current. Disconnects only mark the
	  record "Left"; the loop reacts on its next tick. Every snapshot bumps
	  `version`; every turn has a fresh `turnId`.

	POLICIES
	  • Caller: random in round 1, then the next connected player clockwise
	    who has not called yet (cycles once everyone has).
	  • Turn order: answerers clockwise starting left of the Caller; each turn
	    starts and ends on a beat of the song.
	  • Blank / too long / censored input: InputRejected, the timer keeps
	    running, the player may retry.
	  • Repeat of an accepted answer (repeat key, this round): eliminated at
	    once, before filtering; the Caller cannot override.
	  • Text filter down (two failures): answer → the turn is voided (no
	    elimination); category → a random Config.Match.FallbackCategories entry.
	  • Caller does not judge in time: the answer is ACCEPTED; after
	    MaxConsecutiveTimeouts in a row the round switches to auto-judge.
	  • Caller leaves: pending answer accepted, auto-judge for the rest of
	    the round (fallback category if none was set); the next round picks
	    a new Caller.
	  • Answerer leaves on their own turn: ELIMINATION (Left).
	  • Winner: most round wins, then most accepted answers; ties share.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local AnswerRules = require(Shared.AnswerRules)
local Config = require(Shared.Config)
local MusicTimeline = require(Shared.MusicTimeline)
local Remotes = require(Shared.Remotes)

local CharacterUtil = require(script.Parent.CharacterUtil)
local RoomController = require(script.Parent.RoomController)
local TextFilter = require(script.Parent.TextFilter)

type MatchState = Remotes.MatchState
type PlayerStatus = Remotes.PlayerStatus
type EliminationReason = Remotes.EliminationReason
export type Verdict = "Valid" | "Wrong"

----------------------------------------------------------------------------
-- Tuning that is internal to the server (gameplay values live in Config)
----------------------------------------------------------------------------
local LOOP_TICK = 1 / 30 -- loop polling period; deadlines are checked at this granularity
local STREAM_TIMEOUT = 5 -- RequestStreamAroundAsync timeout per player
local CHARACTER_POLL = 0.25
local RESPAWN_ROOT_WAIT = 5 -- how long a respawned character may take to get its root part
local RESPAWN_SETTLE = 0.1 -- let the engine finish placing a fresh character before moving it
local RESEAT_DELAY = 0.3 -- seat watchdog: re-seat an active player this long after they stand up
local FILTER_HOLD_MAX = 10 -- a filter call still pending this long past a deadline counts as a filter failure
local BEAT_SAFETY = 0.05 -- never schedule a turn on a beat closer than this

if Config.Judging.TimeoutPolicy ~= "Accept" then
	warn(`[Match] Config.Judging.TimeoutPolicy "{Config.Judging.TimeoutPolicy}" is not supported; using "Accept"`)
end

-- Legal transitions (PLAYING -> PLAYING is the next turn). GAME_END and
-- CLEANUP are reachable from everywhere because players can leave anytime.
local ALLOWED: { [string]: { [string]: boolean } } = {
	INTRO = { CALLER_SELECTION = true, GAME_END = true, CLEANUP = true },
	CALLER_SELECTION = { CATEGORY_SELECTION = true, GAME_END = true, CLEANUP = true },
	CATEGORY_SELECTION = { COUNTDOWN = true, GAME_END = true, CLEANUP = true },
	COUNTDOWN = { PLAYING = true, ROUND_END = true, GAME_END = true, CLEANUP = true },
	PLAYING = {
		PLAYING = true,
		JUDGING = true,
		ELIMINATION = true,
		ROUND_END = true,
		GAME_END = true,
		CLEANUP = true,
	},
	JUDGING = { PLAYING = true, ELIMINATION = true, ROUND_END = true, GAME_END = true, CLEANUP = true },
	ELIMINATION = { PLAYING = true, ROUND_END = true, GAME_END = true, CLEANUP = true },
	ROUND_END = { CALLER_SELECTION = true, GAME_END = true, CLEANUP = true },
	GAME_END = { CLEANUP = true },
	CLEANUP = {},
}

-- States in which a round is under way (a Caller exists).
local ROUND_IN_PROGRESS: { [string]: boolean } = {
	CALLER_SELECTION = true,
	CATEGORY_SELECTION = true,
	COUNTDOWN = true,
	PLAYING = true,
	JUDGING = true,
	ELIMINATION = true,
}

local REASON_FOOTER: { [EliminationReason]: string } = {
	Rejected = "GIBBERISH",
	Repeat = "REPEAT",
	Hesitation = "HESITATION",
	Left = "LEFT THE ROOM",
}

local NOTICE_CALLER_LEFT = "The Caller left - answers are auto-judged this round."
local NOTICE_CALLER_TIMEOUTS = "The Caller keeps timing out - answers are auto-judged this round."
local NOTICE_FILTER_TURN = "Filter unavailable - turn passes"
local NOTICE_FILTER_CATEGORY = "Text filter unavailable - a random case file was picked."
local NOTICE_CATEGORY_TIMEOUT = "Time's up - a random case file was picked."
local NOTICE_CATEGORY_NO_CALLER = "No category from the Caller - a random case file was picked."
local TEXT_JUDGE_TIMEOUT = "The Caller didn't judge in time - the answer stands."
local REJECT_CENSORED_ANSWER = "That answer was filtered. Try another one."
local REJECT_CENSORED_CATEGORY = "That category was filtered. Try another one."

----------------------------------------------------------------------------
-- Types
----------------------------------------------------------------------------
type PlayerRecord = {
	player: Player,
	userId: number,
	name: string, -- DisplayName at match start
	seat: number, -- == index in Match.records
	status: PlayerStatus,
	roundWins: number,
	acceptedCount: number,
	wasCaller: boolean,
	reseatPending: boolean,
	lobbyTarget: CFrame?,
	characterConnection: RBXScriptConnection?,
}

type TurnResultKind = "Answer" | "Repeat" | "Voided"

-- Recorded by SubmitAnswer, consumed by the loop.
type TurnResult = {
	kind: TurnResultKind,
	answer: string?, -- Answer: filtered text · Repeat: the accepted text it repeats
	key: string?, -- Answer: repeat key of the cleaned raw text
}

type Turn = {
	id: number,
	record: PlayerRecord,
	startsAt: number,
	endsAt: number,
	startBeat: number,
	endBeat: number,
	submitting: boolean, -- a submission is being filtered: holds the deadline
	result: TurnResult?,
}

type Judging = {
	turnId: number,
	record: PlayerRecord,
	answer: string, -- filtered
	key: string,
	deadline: number,
	verdict: Verdict?, -- recorded by JudgeAnswer, first one wins
}

type PendingCategory = {
	text: string,
	notice: string?,
}

type Elimination = {
	record: PlayerRecord,
	reason: EliminationReason,
}

export type MatchParams = {
	id: string,
	slot: number,
	queueIndex: number,
	room: Model, -- already cloned, positioned and parented by MatchService
	players: { Player }, -- seat order
	releasePlayer: (player: Player) -> (), -- MatchService forgets this player's membership
	onClosed: () -> (), -- MatchService frees the slot
	lobbyTargets: (count: number) -> { CFrame }, -- spread-out lobby landing spots
}

type MatchData = {
	id: string,
	slot: number,
	queueIndex: number,
	roomName: string,
	room: RoomController.RoomController,
	params: MatchParams,
	rng: Random,

	records: { PlayerRecord }, -- sorted by seat
	byPlayer: { [Player]: PlayerRecord },

	state: MatchState,
	stateEndsAt: number?,
	version: number,
	dirty: boolean, -- snapshot-visible data changed outside a transition
	closed: boolean,
	seatingEnabled: boolean,
	connections: { RBXScriptConnection },
	lastSnapshot: Remotes.MatchSnapshot?,

	round: number,
	totalRounds: number,
	caller: PlayerRecord?,
	autoJudge: boolean,
	category: string?,
	categoryRevealed: boolean,
	categorySubmitting: boolean,
	pendingCategory: PendingCategory?,
	musicStartTime: number?,
	turnOrder: { PlayerRecord },
	turnCursor: number, -- index in turnOrder of the current / last turn
	turnCounter: number,
	turn: Turn?,
	judging: Judging?,
	accepted: { Remotes.AcceptedAnswer },
	acceptedKeys: { [string]: string }, -- repeat key -> accepted (filtered) text
	consecutiveTimeouts: number,
	lastVerdict: string?, -- TV footer shown at the start of the next turn
	elimination: Elimination?,
	roundWinner: PlayerRecord?,
	winnerUserIds: { number }?,
}

local Match = {}
Match.__index = Match

export type Match = typeof(setmetatable({} :: MatchData, Match))

local function serverNow(): number
	return Workspace:GetServerTimeNow()
end

-- Status can change while a handler yields, so callers re-read it through
-- this function instead of relying on an earlier comparison.
local function hasLeft(record: PlayerRecord): boolean
	return record.status == "Left"
end

----------------------------------------------------------------------------
-- Construction
----------------------------------------------------------------------------

function Match.new(params: MatchParams): Match
	local records: { PlayerRecord } = {}
	local byPlayer: { [Player]: PlayerRecord } = {}
	for index, player in params.players do
		local record: PlayerRecord = {
			player = player,
			userId = player.UserId,
			name = player.DisplayName,
			seat = index,
			status = "Active",
			roundWins = 0,
			acceptedCount = 0,
			wasCaller = false,
			reseatPending = false,
			lobbyTarget = nil,
			characterConnection = nil,
		}
		records[index] = record
		byPlayer[player] = record
	end

	local self: MatchData = {
		id = params.id,
		slot = params.slot,
		queueIndex = params.queueIndex,
		roomName = params.room.Name,
		room = RoomController.new(params.room, params.slot),
		params = params,
		rng = Random.new(),

		records = records,
		byPlayer = byPlayer,

		-- "INTRO" with version 0 means "loading": nothing has been sent yet
		-- and every remote handler rejects input until the real INTRO.
		state = "INTRO",
		stateEndsAt = nil,
		version = 0,
		dirty = false,
		closed = false,
		seatingEnabled = false,
		connections = {},
		lastSnapshot = nil,

		round = 0,
		totalRounds = 0,
		caller = nil,
		autoJudge = false,
		category = nil,
		categoryRevealed = false,
		categorySubmitting = false,
		pendingCategory = nil,
		musicStartTime = nil,
		turnOrder = {},
		turnCursor = 0,
		turnCounter = 0,
		turn = nil,
		judging = nil,
		accepted = {},
		acceptedKeys = {},
		consecutiveTimeouts = 0,
		lastVerdict = nil,
		elimination = nil,
		roundWinner = nil,
		winnerUserIds = nil,
	}
	return setmetatable(self, Match)
end

-- Starts the match coroutine. Returns immediately.
function Match.start(self: Match)
	task.spawn(function()
		self:run()
	end)
end

function Match.log(self: Match, message: string)
	if Config.Debug.Verbose then
		print(`[Match {self.roomName}] {message}`)
	end
end

----------------------------------------------------------------------------
-- Queries
----------------------------------------------------------------------------

function Match.isConnected(_self: Match, record: PlayerRecord): boolean
	return record.status ~= "Left" and record.player.Parent ~= nil
end

function Match.countConnected(self: Match): number
	local count = 0
	for _, record in self.records do
		if self:isConnected(record) then
			count += 1
		end
	end
	return count
end

-- Active answerers this round (everyone Active except the Caller), plus the
-- last one found (the round winner when the count is 1). Allocation-free.
function Match.countActiveAnswerers(self: Match): (number, PlayerRecord?)
	local count = 0
	local last: PlayerRecord? = nil
	for _, record in self.records do
		if record.status == "Active" and record ~= self.caller then
			count += 1
			last = record
		end
	end
	return count, last
end

function Match.timeUp(self: Match, now: number): boolean
	local endsAt = self.stateEndsAt
	return endsAt == nil or now >= endsAt
end

function Match.getState(self: Match): MatchState
	return self.state
end

function Match.isClosed(self: Match): boolean
	return self.closed
end

----------------------------------------------------------------------------
-- Network output
----------------------------------------------------------------------------

function Match.buildSnapshot(self: Match): Remotes.MatchSnapshot
	local players: { Remotes.MatchPlayer } = table.create(#self.records)
	for _, record in self.records do
		table.insert(players, {
			userId = record.userId,
			name = record.name,
			seat = record.seat,
			role = if record == self.caller then "Caller" else "Answerer",
			status = record.status,
			roundWins = record.roundWins,
			acceptedCount = record.acceptedCount,
		})
	end

	local turnOrder: { number } = table.create(#self.turnOrder)
	for index, record in self.turnOrder do
		turnOrder[index] = record.userId
	end

	local turnInfo: Remotes.TurnInfo? = nil
	local turn = self.turn
	if self.state == "PLAYING" and turn then
		turnInfo = {
			id = turn.id,
			userId = turn.record.userId,
			startsAt = turn.startsAt,
			endsAt = turn.endsAt,
			startBeat = turn.startBeat,
			endBeat = turn.endBeat,
		}
	end

	local judgingInfo: Remotes.JudgingInfo? = nil
	local judging = self.judging
	if self.state == "JUDGING" and judging then
		judgingInfo = {
			turnId = judging.turnId,
			userId = judging.record.userId,
			answer = judging.answer,
			deadline = judging.deadline,
		}
	end

	local caller = self.caller
	local roundWinner = self.roundWinner
	local winners = self.winnerUserIds
	return {
		matchId = self.id,
		version = self.version,
		state = self.state,
		stateEndsAt = self.stateEndsAt,
		roomName = self.roomName,
		slot = self.slot,
		round = self.round,
		totalRounds = self.totalRounds,
		players = players,
		callerUserId = if caller then caller.userId else nil,
		autoJudge = self.autoJudge,
		category = self.category,
		musicStartTime = self.musicStartTime,
		turnOrder = turnOrder,
		turn = turnInfo,
		judging = judgingInfo,
		accepted = table.clone(self.accepted),
		roundWinnerUserId = if roundWinner then roundWinner.userId else nil,
		winnerUserIds = if winners then table.clone(winners) else nil,
	}
end

-- Sends a fresh snapshot (new version) to every connected participant,
-- eliminated spectators included.
function Match.pushSnapshot(self: Match)
	self.version += 1
	self.dirty = false
	local snapshot = self:buildSnapshot()
	self.lastSnapshot = snapshot
	for _, record in self.records do
		if self:isConnected(record) then
			Remotes.MatchSnapshot:FireClient(record.player, snapshot)
		end
	end
end

function Match.fireEvent(self: Match, event: Remotes.MatchEvent)
	for _, record in self.records do
		if self:isConnected(record) then
			Remotes.MatchEvent:FireClient(record.player, event)
		end
	end
end

function Match.fireNotice(self: Match, text: string)
	self:fireEvent({ matchId = self.id, kind = "Notice", text = text })
end

-- The ClientState.match for GetState: the last snapshot this player was sent.
function Match.snapshotFor(self: Match, player: Player): Remotes.MatchSnapshot?
	local record = self.byPlayer[player]
	if self.closed or not record or not self:isConnected(record) then
		return nil
	end
	return self.lastSnapshot
end

----------------------------------------------------------------------------
-- TV
----------------------------------------------------------------------------

function Match.refreshTV(self: Match)
	local state = self.state
	if state == "CLEANUP" then
		return
	end
	local roomLabel = `ROOM {self.slot + 1}`
	local header = if self.round > 0 then `{roomLabel}  ·  ROUND {self.round}/{self.totalRounds}` else roomLabel
	local category = self.category
	local categoryText = if category and (state ~= "COUNTDOWN" or self.categoryRevealed)
		then string.upper(category)
		else "--"
	local caller = self.caller
	local callerName = if caller then string.upper(caller.name) else ""

	local speaker, answer, footer = "", "", ""
	if state == "INTRO" then
		answer = "CONCENTRATION 64"
		footer = "NO REPEATS. NO HESITATION."
	elseif state == "CALLER_SELECTION" then
		speaker = callerName
		answer = "IS THE CALLER"
		footer = "CALLER SELECTED"
	elseif state == "CATEGORY_SELECTION" then
		speaker = callerName
		answer = "..."
		footer = "AWAITING CALLER"
	elseif state == "COUNTDOWN" then
		answer = if self.categoryRevealed then "THE CATEGORY IS..." else "CONCENTRATION 64"
		footer = "NO REPEATS. NO HESITATION."
	elseif state == "PLAYING" then
		local turn = self.turn
		speaker = if turn then string.upper(turn.record.name) else ""
		answer = "..."
		footer = self.lastVerdict or "ANSWER NOW"
	elseif state == "JUDGING" then
		local judging = self.judging
		speaker = if judging then string.upper(judging.record.name) else ""
		answer = if judging then string.upper(judging.answer) else ""
		footer = "CALLER JUDGING"
	elseif state == "ELIMINATION" then
		local elimination = self.elimination
		speaker = if elimination then string.upper(elimination.record.name) else ""
		answer = "ELIMINATED"
		footer = if elimination then REASON_FOOTER[elimination.reason] else ""
	elseif state == "ROUND_END" then
		local winner = self.roundWinner
		speaker = if winner then string.upper(winner.name) else ""
		answer = if winner then "WINS THE ROUND" else "NO SURVIVORS"
		footer = `ROUND {self.round} CLOSED`
	elseif state == "GAME_END" then
		local names: { string } = {}
		local winnerIds: { number } = self.winnerUserIds or {}
		for _, userId in winnerIds do
			for _, record in self.records do
				if record.userId == userId then
					table.insert(names, string.upper(record.name))
				end
			end
		end
		speaker = table.concat(names, " & ")
		answer = if #names > 1 then "SHARED VICTORY" elseif #names == 1 then "WINS THE CASE" else "CASE DISMISSED"
		footer = "CASE CLOSED"
	end

	self.room:setTV({
		header = header,
		category = categoryText,
		speaker = speaker,
		answer = answer,
		footer = footer,
	})
end

----------------------------------------------------------------------------
-- State machine core
----------------------------------------------------------------------------

-- Enters `newState` (or re-enters PLAYING for the next turn), bumps the
-- version and pushes a snapshot. The very first call (version 0) ends the
-- loading phase and is always legal.
function Match.transition(self: Match, newState: MatchState, endsAt: number?)
	local from = self.state
	if self.version > 0 and not ALLOWED[from][newState] then
		warn(`[Match {self.roomName}] unexpected transition {from} -> {newState}`)
	end
	self.state = newState
	self.stateEndsAt = endsAt
	if Config.Debug.Verbose then
		self:log(`{from} -> {newState}` .. (if endsAt then string.format(" (%.2fs)", endsAt - serverNow()) else ""))
	end
	self:refreshTV()
	self:pushSnapshot()
end

function Match.run(self: Match)
	local ok, err = xpcall(function()
		self:loadPlayers()
		while not self.closed do
			self:step(serverNow())
			if self.closed then
				break
			end
			if self.dirty then
				self:pushSnapshot()
			end
			task.wait(LOOP_TICK)
		end
	end, debug.traceback)
	if not ok then
		-- Never strand players in a dead room: clean up whatever happened.
		warn(`[Match {self.roomName}] loop crashed, cleaning up: {err}`)
		self:cleanup()
	end
end

-- One loop iteration: global population rules first, then the current state.
function Match.step(self: Match, now: number)
	local state = self.state
	if state == "GAME_END" then
		if self:timeUp(now) then
			self:cleanup()
		end
		return
	end

	local connected = self:countConnected()
	if connected == 0 then
		self:log("nobody left: cleanup")
		self:cleanup()
		return
	end
	if connected < Config.Match.MinPlayersToContinue then
		self:endEarly(now)
		return
	end

	local caller = self.caller
	if ROUND_IN_PROGRESS[state] and caller and caller.status == "Left" then
		self:setAutoJudge(NOTICE_CALLER_LEFT)
	end

	if state == "INTRO" then
		if self:timeUp(now) then
			self:beginRound(now)
		end
	elseif state == "CALLER_SELECTION" then
		if self:timeUp(now) then
			self:transition("CATEGORY_SELECTION", now + Config.Match.CategoryTimeoutSeconds)
		end
	elseif state == "CATEGORY_SELECTION" then
		self:stepCategorySelection(now)
	elseif state == "COUNTDOWN" then
		self:stepCountdown(now)
	elseif state == "PLAYING" then
		self:stepPlaying(now)
	elseif state == "JUDGING" then
		self:stepJudging(now)
	elseif state == "ELIMINATION" then
		if self:timeUp(now) then
			self:continueRound(now)
		end
	elseif state == "ROUND_END" then
		if self:timeUp(now) then
			if self.round < self.totalRounds and connected >= Config.Match.MinPlayersToContinue then
				self:beginRound(now)
			else
				self:enterGameEnd(now)
			end
		end
	end
end

----------------------------------------------------------------------------
-- Loading (before INTRO)
----------------------------------------------------------------------------

function Match.loadPlayers(self: Match)
	for _, record in self.records do
		-- Nobody wanders out of the elevator while the room streams in.
		CharacterUtil.lockMovement(record.player)
		record.characterConnection = record.player.CharacterAdded:Connect(function(character: Model)
			self:onCharacterAdded(record, character)
		end)
	end

	self:streamRoom()
	self:waitForCharacters()

	self.totalRounds = if Config.Match.RoundsPerMatch > 0
		then Config.Match.RoundsPerMatch
		else math.max(self:countConnected(), 1)

	self.seatingEnabled = true
	for _, record in self.records do
		if record.status == "Active" then
			self:placeRecord(record)
		end
	end
	self:connectSeatWatchdog()
	self:transition("INTRO", serverNow() + Config.Match.IntroSeconds)
end

-- Asks every client to stream in the area around its seat, all at once,
-- bounded by STREAM_TIMEOUT. Failures are harmless (the room model is
-- PersistentPerPlayer anyway); this just avoids landing in a void.
function Match.streamRoom(self: Match)
	local pending = 0
	for _, record in self.records do
		if record.status ~= "Left" then
			pending += 1
			local target = self.room:seatPosition(record.seat)
			task.spawn(function()
				local ok, err = pcall(function()
					record.player:RequestStreamAroundAsync(target, STREAM_TIMEOUT)
				end)
				if not ok then
					self:log(`stream request for {record.player.Name} failed: {err}`)
				end
				pending -= 1
			end)
		end
	end
	local deadline = serverNow() + STREAM_TIMEOUT + 1
	while pending > 0 and serverNow() < deadline do
		task.wait(0.1)
	end
end

function Match.waitForCharacters(self: Match)
	local deadline = serverNow() + Config.Match.CharacterWaitSeconds
	while serverNow() < deadline do
		local missing = false
		for _, record in self.records do
			if record.status ~= "Left" and not CharacterUtil.isAlive(record.player) then
				missing = true
				break
			end
		end
		if not missing then
			return
		end
		task.wait(CHARACTER_POLL)
	end
	for _, record in self.records do
		if record.status ~= "Left" and not CharacterUtil.isAlive(record.player) then
			self:dropUnloaded(record)
		end
	end
end

-- A player whose character never appeared counts as Left and is handed back
-- to the lobby systems (they can queue again).
function Match.dropUnloaded(self: Match, record: PlayerRecord)
	warn(`[Match {self.roomName}] {record.player.Name} never loaded a character; treating as Left`)
	record.status = "Left"
	if record.characterConnection then
		record.characterConnection:Disconnect()
		record.characterConnection = nil
	end
	self.room:getModel():RemovePersistentPlayer(record.player)
	self.params.releasePlayer(record.player)
	CharacterUtil.unlockMovement(record.player)
	if record.player.Parent then
		Remotes.Notify:FireClient(record.player, "Couldn't load you into the interrogation room.", "Error")
	end
end

----------------------------------------------------------------------------
-- Character placement, respawns and the seat watchdog
----------------------------------------------------------------------------

function Match.sendToLounge(self: Match, record: PlayerRecord)
	local spawnPart = self.room:spectatorSpawnFor(record.userId)
	if spawnPart then
		CharacterUtil.teleport(record.player, spawnPart.CFrame)
	else
		warn(`[Match {self.roomName}] no spectator spawn for {record.player.Name}`)
	end
	CharacterUtil.unlockMovement(record.player)
end

-- Puts a player where their status says they belong: Active -> their seat
-- (movement locked), Eliminated -> the spectator lounge (free to walk).
function Match.placeRecord(self: Match, record: PlayerRecord)
	if record.status == "Active" then
		CharacterUtil.lockMovement(record.player)
		local seat = self.room:getSeat(record.seat)
		if seat then
			CharacterUtil.seat(record.player, seat)
		else
			CharacterUtil.teleport(record.player, CFrame.new(self.room:seatPosition(record.seat)))
		end
	elseif record.status == "Eliminated" then
		self:sendToLounge(record)
	end
end

function Match.onCharacterAdded(self: Match, record: PlayerRecord, character: Model)
	if self.closed or not self.seatingEnabled or record.status == "Left" then
		return
	end
	local root = CharacterUtil.waitForRoot(character, RESPAWN_ROOT_WAIT)
	if not root then
		return
	end
	task.wait(RESPAWN_SETTLE)
	if self.closed or not self.seatingEnabled or hasLeft(record) or record.player.Character ~= character then
		return
	end
	self:log(`{record.player.Name} respawned; placing ({record.status})`)
	self:placeRecord(record)
end

function Match.scheduleReseat(self: Match, record: PlayerRecord)
	if record.reseatPending then
		return
	end
	record.reseatPending = true
	task.delay(RESEAT_DELAY, function()
		record.reseatPending = false
		if self.closed or not self.seatingEnabled or record.status ~= "Active" then
			return
		end
		local seat = self.room:getSeat(record.seat)
		local humanoid = CharacterUtil.getHumanoid(record.player)
		if seat and humanoid and seat.Occupant ~= humanoid then
			CharacterUtil.lockMovement(record.player)
			CharacterUtil.seat(record.player, seat)
		end
	end)
end

-- Seat watchdog: an active player who stands up (jump, physics glitch) is
-- re-seated shortly after; anybody else sitting in a match seat is ejected.
function Match.onSeatOccupantChanged(self: Match, seatNumber: number, seat: Seat)
	if self.closed or not self.seatingEnabled then
		return
	end
	local owner = self.records[seatNumber]
	local occupant = seat.Occupant
	if occupant then
		local ownerHumanoid = if owner and owner.status == "Active"
			then CharacterUtil.getHumanoid(owner.player)
			else nil
		if occupant == ownerHumanoid then
			return
		end
		CharacterUtil.unseatHumanoid(occupant)
		local character = occupant.Parent
		local intruder = if character and character:IsA("Model") then Players:GetPlayerFromCharacter(character) else nil
		local intruderRecord = if intruder then self.byPlayer[intruder] else nil
		self:log(`ejected {if intruder then intruder.Name else "a humanoid"} from seat {seatNumber}`)
		if intruderRecord and intruderRecord.status == "Active" then
			self:scheduleReseat(intruderRecord) -- a participant in the wrong seat goes back to their own
		end
	elseif owner and owner.status == "Active" then
		self:scheduleReseat(owner)
	end
end

function Match.connectSeatWatchdog(self: Match)
	for seatNumber = 1, self.room:getSeatCount() do
		local seat = self.room:getSeat(seatNumber)
		if seat then
			table.insert(
				self.connections,
				seat:GetPropertyChangedSignal("Occupant"):Connect(function()
					self:onSeatOccupantChanged(seatNumber, seat)
				end)
			)
		end
	end
end

----------------------------------------------------------------------------
-- Rounds
----------------------------------------------------------------------------

function Match.chooseCaller(self: Match): PlayerRecord?
	local records = self.records
	local previous = self.caller
	if not previous then
		local candidates: { PlayerRecord } = {}
		for _, record in records do
			if self:isConnected(record) then
				table.insert(candidates, record)
			end
		end
		if #candidates == 0 then
			return nil
		end
		return candidates[self.rng:NextInteger(1, #candidates)]
	end

	-- Clockwise from the previous Caller: first connected player who has not
	-- called yet; if everyone has, simply the next connected player.
	local count = #records
	local fallback: PlayerRecord? = nil
	for offset = 1, count do
		local record = records[(previous.seat - 1 + offset) % count + 1]
		if self:isConnected(record) then
			if not record.wasCaller then
				return record
			end
			fallback = fallback or record
		end
	end
	return fallback
end

-- Answerers in seat order starting with the seat LEFT of the Caller (the
-- next seat number), wrapping around.
function Match.buildTurnOrder(self: Match): { PlayerRecord }
	local order: { PlayerRecord } = {}
	local caller = self.caller
	local count = #self.records
	local callerSeat = if caller then caller.seat else 0
	for offset = 1, count do
		local record = self.records[(callerSeat - 1 + offset) % count + 1]
		if record ~= caller and record.status == "Active" then
			table.insert(order, record)
		end
	end
	return order
end

function Match.beginRound(self: Match, now: number)
	self.round += 1
	self.category = nil
	self.categoryRevealed = false
	self.categorySubmitting = false
	self.pendingCategory = nil
	self.musicStartTime = nil
	self.turn = nil
	self.judging = nil
	self.turnCursor = 0
	self.accepted = {}
	self.acceptedKeys = {}
	self.autoJudge = false
	self.consecutiveTimeouts = 0
	self.lastVerdict = nil
	self.elimination = nil
	self.roundWinner = nil

	-- Everyone still here sits back down as an active player.
	self.room:clearSpectatorSpawns()
	for _, record in self.records do
		if record.status ~= "Left" then
			record.status = "Active"
			self:placeRecord(record)
		end
	end

	local caller = self:chooseCaller()
	self.caller = caller
	if caller then
		caller.wasCaller = true
	end
	self.turnOrder = self:buildTurnOrder()
	self:transition("CALLER_SELECTION", now + Config.Match.CallerRevealSeconds)
end

function Match.fallbackCategory(self: Match): string
	local list = Config.Match.FallbackCategories
	if #list == 0 then
		return "Anything"
	end
	return list[self.rng:NextInteger(1, #list)]
end

function Match.setAutoJudge(self: Match, notice: string)
	if self.autoJudge then
		return
	end
	self.autoJudge = true
	self.dirty = true
	self:log("auto-judge on")
	self:fireNotice(notice)
end

function Match.stepCategorySelection(self: Match, now: number)
	local pending = self.pendingCategory
	if pending then
		self.pendingCategory = nil
		self:startCountdown(now, pending.text, pending.notice)
		return
	end

	local caller = self.caller
	if not caller or caller.status == "Left" then
		self:setAutoJudge(NOTICE_CALLER_LEFT)
		self:startCountdown(now, self:fallbackCategory(), NOTICE_CATEGORY_NO_CALLER)
		return
	end

	-- A category being filtered holds the timeout (bounded by FILTER_HOLD_MAX).
	local endsAt = self.stateEndsAt or now
	if self.categorySubmitting then
		if now <= endsAt + FILTER_HOLD_MAX then
			return
		end
	elseif now < endsAt then
		return
	end
	self:startCountdown(now, self:fallbackCategory(), NOTICE_CATEGORY_TIMEOUT)
end

-- Locks the category in and schedules the song: chant, sting (category
-- reveal), then the loop where turn 1 begins.
function Match.startCountdown(self: Match, now: number, category: string, notice: string?)
	self.category = category
	self.categorySubmitting = false
	self.categoryRevealed = false
	local musicStart = now + Config.Music.StartLeadInSeconds
	self.musicStartTime = musicStart
	self:transition("COUNTDOWN", musicStart + MusicTimeline.timeOfBeat(MusicTimeline.LoopStartBeat))
	if notice then
		self:fireNotice(notice)
	end
end

function Match.stepCountdown(self: Match, now: number)
	local musicStart = self.musicStartTime
	if
		not self.categoryRevealed
		and musicStart
		and now >= musicStart + MusicTimeline.timeOfBeat(MusicTimeline.StingStartBeat)
	then
		-- The sting: the TV reveals the category together with the clients.
		self.categoryRevealed = true
		self:refreshTV()
	end
	if self:timeUp(now) then
		self:startNextTurn(now, true)
	end
end

----------------------------------------------------------------------------
-- Turns
----------------------------------------------------------------------------

-- Next Active answerer after the current cursor (cyclic). Allocation-free.
function Match.nextAnswerer(self: Match): (PlayerRecord?, number)
	local order = self.turnOrder
	local count = #order
	for offset = 1, count do
		local index = (self.turnCursor + offset - 1) % count + 1
		local record = order[index]
		if record.status == "Active" and record ~= self.caller then
			return record, index
		end
	end
	return nil, 0
end

-- Opens the next turn on the beat grid, or ends the round when at most one
-- answerer is left. The first turn of a round starts exactly on the first
-- beat of the gameplay loop; later turns start on the next beat (plus
-- GapBeats - 1) after now.
function Match.startNextTurn(self: Match, now: number, isFirst: boolean)
	local active = self:countActiveAnswerers()
	if active <= 1 then
		self:enterRoundEnd(now)
		return
	end
	local record, index = self:nextAnswerer()
	if not record then
		self:enterRoundEnd(now)
		return
	end

	-- Music always starts in COUNTDOWN; defensively pretend the loop starts now otherwise.
	local musicStart: number = self.musicStartTime or (now - MusicTimeline.timeOfBeat(MusicTimeline.LoopStartBeat))
	self.musicStartTime = musicStart

	local startBeat = MusicTimeline.LoopStartBeat
	if not isFirst then
		local songNow = now - musicStart
		startBeat = MusicTimeline.nextBeat(songNow + BEAT_SAFETY, MusicTimeline.LoopStartBeat)
			+ math.max(Config.Turn.GapBeats - 1, 0)
	end
	local endBeat = startBeat + MusicTimeline.beatsPerTurn()

	self.turnCounter += 1
	self.turnCursor = index
	self.judging = nil
	self.elimination = nil
	local turn: Turn = {
		id = self.turnCounter,
		record = record,
		startsAt = musicStart + MusicTimeline.timeOfBeat(startBeat),
		endsAt = musicStart + MusicTimeline.timeOfBeat(endBeat),
		startBeat = startBeat,
		endBeat = endBeat,
		submitting = false,
		result = nil,
	}
	self.turn = turn
	self:transition("PLAYING", turn.endsAt)
end

function Match.continueRound(self: Match, now: number)
	if self:countActiveAnswerers() <= 1 then
		self:enterRoundEnd(now)
	else
		self:startNextTurn(now, false)
	end
end

function Match.stepPlaying(self: Match, now: number)
	local turn = self.turn
	if not turn then
		self:continueRound(now)
		return
	end
	local record = turn.record
	if record.status == "Left" then
		self:eliminate(now, record, "Left", nil)
		return
	end

	local result = turn.result
	if result then
		turn.result = nil
		self:resolveSubmission(now, turn, result)
		return
	end

	if self:countActiveAnswerers() <= 1 then
		self:enterRoundEnd(now)
		return
	end

	local deadline = turn.endsAt + Config.Turn.LatencyGraceSeconds
	if turn.submitting then
		-- The answer is being filtered: the deadline waits, but not forever.
		if now > deadline + FILTER_HOLD_MAX then
			self:log("filter call hung; voiding the turn")
			self:voidTurn(now)
		end
	elseif now > deadline then
		self:eliminate(now, record, "Hesitation", nil)
	end
end

function Match.resolveSubmission(self: Match, now: number, turn: Turn, result: TurnResult)
	if result.kind == "Repeat" then
		self:eliminate(now, turn.record, "Repeat", result.answer)
	elseif result.kind == "Voided" then
		self:voidTurn(now)
	else
		local answer = result.answer or ""
		local key = result.key or AnswerRules.key(answer)
		if self.autoJudge then
			self:acceptAnswer(turn.record, answer, key)
			self:startNextTurn(now, false)
		else
			self:enterJudging(now, turn, answer, key)
		end
	end
end

function Match.voidTurn(self: Match, now: number)
	self:fireNotice(NOTICE_FILTER_TURN)
	self.lastVerdict = "PASS"
	self:startNextTurn(now, false)
end

-- Records an accepted answer. `footer` is what the TV shows at the start of
-- the next turn ("VALID" for a real or automatic verdict, "ACCEPTED" when
-- the answer only stands because nobody judged it).
function Match.acceptAnswer(self: Match, record: PlayerRecord, answer: string, key: string, footer: string?)
	self.acceptedKeys[key] = answer
	table.insert(self.accepted, { answer = answer, userId = record.userId, name = record.name })
	record.acceptedCount += 1
	self.lastVerdict = footer or "VALID"
	self.dirty = true
	self:fireEvent({ matchId = self.id, kind = "Accepted", userId = record.userId, answer = answer })
end

function Match.enterJudging(self: Match, now: number, turn: Turn, answer: string, key: string)
	local judging: Judging = {
		turnId = turn.id,
		record = turn.record,
		answer = answer,
		key = key,
		deadline = now + Config.Judging.TimeoutSeconds,
		verdict = nil,
	}
	self.judging = judging
	self:transition("JUDGING", judging.deadline)
end

function Match.stepJudging(self: Match, now: number)
	local judging = self.judging
	if not judging then
		self:continueRound(now)
		return
	end
	local record = judging.record
	if record.status == "Left" then
		-- The answerer walked out while being judged: their answer goes with them.
		self:eliminate(now, record, "Left", nil)
		return
	end

	local verdict = judging.verdict
	local caller = self.caller
	if verdict == "Valid" then
		self.consecutiveTimeouts = 0
		self:acceptAnswer(record, judging.answer, judging.key)
		self:startNextTurn(now, false)
	elseif verdict == "Wrong" then
		self.consecutiveTimeouts = 0 -- the Caller answered: the timeout streak is broken
		self:eliminate(now, record, "Rejected", judging.answer)
	elseif not caller or caller.status == "Left" then
		self:acceptAnswer(record, judging.answer, judging.key, "ACCEPTED")
		self:setAutoJudge(NOTICE_CALLER_LEFT)
		self:startNextTurn(now, false)
	elseif now > judging.deadline + Config.Turn.LatencyGraceSeconds then
		-- TimeoutPolicy "Accept": silence is never proof of a wrong answer.
		self:acceptAnswer(record, judging.answer, judging.key, "ACCEPTED")
		self.consecutiveTimeouts += 1
		self:fireEvent({
			matchId = self.id,
			kind = "JudgeTimeout",
			userId = record.userId,
			answer = judging.answer,
			text = TEXT_JUDGE_TIMEOUT,
		})
		if self.consecutiveTimeouts >= Config.Judging.MaxConsecutiveTimeouts then
			self:setAutoJudge(NOTICE_CALLER_TIMEOUTS)
		end
		self:startNextTurn(now, false)
	end
end

function Match.eliminate(self: Match, now: number, record: PlayerRecord, reason: EliminationReason, answer: string?)
	self.turn = nil
	self.judging = nil
	self.lastVerdict = nil
	-- Status first: the seat watchdog must not pull the player back.
	if reason ~= "Left" then
		record.status = "Eliminated"
	end
	self.elimination = { record = record, reason = reason }
	self:transition("ELIMINATION", now + Config.Match.EliminationSeconds)
	self:fireEvent({
		matchId = self.id,
		kind = "Eliminated",
		userId = record.userId,
		reason = reason,
		answer = answer,
	})
	if record.status == "Eliminated" then
		self:sendToLounge(record)
	end
end

----------------------------------------------------------------------------
-- Round / game end
----------------------------------------------------------------------------

function Match.awardRound(self: Match, record: PlayerRecord)
	self.roundWinner = record
	record.roundWins += 1
	self.dirty = true
end

function Match.enterRoundEnd(self: Match, now: number)
	local count, last = self:countActiveAnswerers()
	local winner = if count == 1 then last else nil
	if winner then
		self:awardRound(winner)
	end
	self.turn = nil
	self.judging = nil
	self.musicStartTime = nil
	self:transition("ROUND_END", now + Config.Match.RoundEndSeconds)
	if winner then
		self:fireEvent({ matchId = self.id, kind = "RoundWinner", userId = winner.userId })
	else
		self:fireNotice("Nobody survived the round.")
	end
end

-- Too few players to continue: the last active answerer (if exactly one)
-- takes the round in progress, then the game ends.
function Match.endEarly(self: Match, now: number)
	self:log("not enough players to continue")
	if ROUND_IN_PROGRESS[self.state] then
		local count, last = self:countActiveAnswerers()
		if count == 1 and last then
			self:awardRound(last)
			self:fireEvent({ matchId = self.id, kind = "RoundWinner", userId = last.userId })
		end
	end
	self:enterGameEnd(now)
end

-- Most round wins, then most accepted answers; remaining ties share the win.
-- Nobody wins a game in which nobody scored anything.
function Match.computeWinners(self: Match): { number }
	local best: { PlayerRecord } = {}
	local bestWins, bestAccepted = -1, -1
	for _, record in self.records do
		if self:isConnected(record) then
			if
				record.roundWins > bestWins
				or (record.roundWins == bestWins and record.acceptedCount > bestAccepted)
			then
				bestWins, bestAccepted = record.roundWins, record.acceptedCount
				table.clear(best)
				table.insert(best, record)
			elseif record.roundWins == bestWins and record.acceptedCount == bestAccepted then
				table.insert(best, record)
			end
		end
	end
	local winners: { number } = {}
	if bestWins <= 0 and bestAccepted <= 0 then
		return winners
	end
	for _, record in best do
		table.insert(winners, record.userId)
	end
	return winners
end

-- Picks each connected player's lobby landing spot now and starts streaming
-- it in, so CLEANUP can teleport without anyone landing in an empty void.
function Match.prepareLobbyReturn(self: Match)
	local connected: { PlayerRecord } = {}
	for _, record in self.records do
		if self:isConnected(record) then
			table.insert(connected, record)
		end
	end
	local targets = self.params.lobbyTargets(#connected)
	for index, record in connected do
		local target = targets[index]
		record.lobbyTarget = target
		if target then
			task.spawn(function()
				pcall(function()
					record.player:RequestStreamAroundAsync(target.Position, STREAM_TIMEOUT)
				end)
			end)
		end
	end
end

function Match.enterGameEnd(self: Match, now: number)
	self.turn = nil
	self.judging = nil
	self.musicStartTime = nil
	self.elimination = nil
	local winners = self:computeWinners()
	self.winnerUserIds = winners
	self:prepareLobbyReturn()
	self:transition("GAME_END", now + Config.Match.GameEndSeconds)
	if #winners > 0 then
		self:fireEvent({ matchId = self.id, kind = "Victory", userIds = table.clone(winners) })
	else
		self:fireNotice("Case dismissed - no winner.")
	end
end

----------------------------------------------------------------------------
-- Cleanup
----------------------------------------------------------------------------

local function safely(match: Match, label: string, fn: () -> ...any)
	local ok, err = pcall(fn)
	if not ok then
		warn(`[Match {match.roomName}] cleanup step "{label}" failed: {err}`)
	end
end

function Match.returnPlayersToLobby(self: Match)
	local needTargets: { PlayerRecord } = {}
	for _, record in self.records do
		if self:isConnected(record) and not record.lobbyTarget then
			table.insert(needTargets, record)
		end
	end
	local fresh = if #needTargets > 0 then self.params.lobbyTargets(#needTargets) else {}
	for index, record in needTargets do
		record.lobbyTarget = fresh[index]
	end

	for _, record in self.records do
		if self:isConnected(record) then
			local player = record.player
			local target = record.lobbyTarget
			if target and CharacterUtil.teleport(player, target) then
				CharacterUtil.unlockMovement(player)
			elseif CharacterUtil.isAlive(player) then
				-- Nowhere to put them: a fresh character spawns at a SpawnLocation.
				task.spawn(function()
					pcall(function()
						player:LoadCharacterAsync()
					end)
				end)
			end
		end
	end
end

-- Ends the match for good. Order matters: final CLEANUP snapshot first (the
-- clients switch back to lobby mode), then the lobby teleport, then the
-- membership release, then connections, the room and finally the slot.
-- Idempotent and safe to call from the crash handler.
function Match.cleanup(self: Match)
	if self.closed then
		return
	end
	self.closed = true -- stops the loop and makes every in-flight handler bail out
	self.seatingEnabled = false
	self.turn = nil
	self.judging = nil
	self.musicStartTime = nil

	safely(self, "final snapshot", function()
		self:transition("CLEANUP", nil)
	end)
	safely(self, "return players", function()
		self:returnPlayersToLobby()
	end)
	for _, record in self.records do
		if record.characterConnection then
			record.characterConnection:Disconnect()
			record.characterConnection = nil
		end
		safely(self, "release player", function()
			self.params.releasePlayer(record.player)
		end)
	end
	for _, connection in self.connections do
		connection:Disconnect()
	end
	table.clear(self.connections)
	safely(self, "destroy room", function()
		self.room:destroy()
	end)
	safely(self, "free slot", self.params.onClosed)
	self:log("closed")
end

----------------------------------------------------------------------------
-- Remote input (validated by MatchService for types; validated here for
-- role, state, turn and timing). Handlers only RECORD; the loop acts.
----------------------------------------------------------------------------

function Match.submitCategory(self: Match, player: Player, text: string)
	if self.closed or self.state ~= "CATEGORY_SELECTION" then
		return
	end
	local caller = self.caller
	if not caller or caller.player ~= player or caller.status == "Left" then
		return
	end
	if self.category ~= nil or self.pendingCategory ~= nil or self.categorySubmitting then
		return -- the category is final once set; one filter call at a time
	end

	local ok, cleanedOrReason = AnswerRules.validateCategory(text)
	if not ok then
		Remotes.InputRejected:FireClient(player, "Category", cleanedOrReason)
		return
	end

	local round = self.round
	self.categorySubmitting = true
	local filterOk, filtered = TextFilter.forBroadcast(cleanedOrReason, player.UserId)
	-- Anything may have happened while the filter yielded.
	if self.closed or self.round ~= round or self.state ~= "CATEGORY_SELECTION" then
		return
	end
	self.categorySubmitting = false

	if not filterOk then
		self.pendingCategory = { text = self:fallbackCategory(), notice = NOTICE_FILTER_CATEGORY }
	elseif AnswerRules.wasCensored(cleanedOrReason, filtered) then
		Remotes.InputRejected:FireClient(player, "Category", REJECT_CENSORED_CATEGORY)
	else
		self.pendingCategory = { text = filtered, notice = nil }
	end
end

function Match.submitAnswer(self: Match, player: Player, turnId: number, text: string)
	local arrivedAt = serverNow()
	if self.closed or self.state ~= "PLAYING" then
		return
	end
	local turn = self.turn
	if not turn or turn.id ~= turnId or turn.record.player ~= player or turn.record.status ~= "Active" then
		return
	end
	if turn.submitting or turn.result ~= nil then
		return -- one well-formed submission at a time; the first decided one wins
	end
	if arrivedAt > turn.endsAt + Config.Turn.LatencyGraceSeconds then
		return -- too late; the loop eliminates for hesitation
	end

	local ok, cleanedOrReason = AnswerRules.validateAnswer(text)
	if not ok then
		Remotes.InputRejected:FireClient(player, "Answer", cleanedOrReason)
		return
	end
	local cleaned = cleanedOrReason

	-- Repeats are decided on the raw key BEFORE filtering: no override, no wait.
	local key = AnswerRules.key(cleaned)
	local repeated = self.acceptedKeys[key]
	if repeated then
		turn.result = { kind = "Repeat", answer = repeated }
		return
	end

	turn.submitting = true
	local filterOk, filtered = TextFilter.forBroadcast(cleaned, player.UserId)
	if self.closed or self.state ~= "PLAYING" or self.turn ~= turn then
		return -- the turn ended while we were filtering (left, voided, match over)
	end
	turn.submitting = false

	if not filterOk then
		turn.result = { kind = "Voided" }
		return
	end
	if AnswerRules.wasCensored(cleaned, filtered) then
		Remotes.InputRejected:FireClient(player, "Answer", REJECT_CENSORED_ANSWER)
		return -- may retry while the turn lasts
	end
	local repeatedLate = self.acceptedKeys[key]
	if repeatedLate then
		turn.result = { kind = "Repeat", answer = repeatedLate }
		return
	end
	turn.result = { kind = "Answer", answer = filtered, key = key }
end

function Match.judgeAnswer(self: Match, player: Player, turnId: number, verdict: Verdict)
	local arrivedAt = serverNow()
	if self.closed or self.state ~= "JUDGING" or self.autoJudge then
		return
	end
	local judging = self.judging
	if not judging or judging.turnId ~= turnId or judging.verdict ~= nil then
		return
	end
	local caller = self.caller
	if not caller or caller.player ~= player or caller.status == "Left" then
		return
	end
	if arrivedAt > judging.deadline + Config.Turn.LatencyGraceSeconds then
		return -- the timeout policy already applies
	end
	judging.verdict = verdict
end

-- PlayerRemoving (via MatchService). Only marks the record; the loop reacts.
function Match.onPlayerLeft(self: Match, player: Player)
	local record = self.byPlayer[player]
	if not record or record.status == "Left" then
		return
	end
	record.status = "Left"
	if record.characterConnection then
		record.characterConnection:Disconnect()
		record.characterConnection = nil
	end
	self.dirty = true
	self:log(`{player.Name} left`)
end

return Match
