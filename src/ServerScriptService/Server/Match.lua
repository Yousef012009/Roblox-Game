--!strict
--[[
	Match  (ModuleScript)  ·  ServerScriptService/Server/Match

	ONE match: its participants, its cloned room and its rounds. Every piece
	of mutable state lives on the instance (no module-level round variables),
	so any number of matches run side by side. Created by MatchService.

	PARTICIPANTS
	  A record is a human (record.player) or an AI detective (record.isBot,
	  record.player == nil, a negative userId, a name from Config.Bots.Names
	  and a BotRig body in the room's "Bots" folder). Humans and bots are
	  shuffled together and spread evenly over the room's seats in clockwise
	  order (RoomController.spreadSeats: 4 of 8 seats -> 1, 3, 5, 7);
	  records are kept in that clockwise order (record.index). Bots never
	  leave; when no human is connected any more the match is CLEANed UP at
	  once. MinPlayersToContinue counts bots. Bots act through the same
	  validated input paths as humans (submitCategoryFrom / submitAnswerFrom /
	  judgeAnswerFrom), driven by BotBrain from tracked threads that re-check
	  the match, state and turn after every wait and are cancelled at CLEANUP.

	STATE MACHINE  (Remotes.MatchState, docs/ARCHITECTURE.md §4)

	  (load: stream the room, wait for characters, build bot bodies, seat everyone, lock movement)
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
	  • Rounds: Config.Match.RoundsPerMatch, or (0) one per HUMAN (min 1).
	  • Caller: humans who have not called yet are preferred (random in round
	    1, then the next one clockwise); with exactly one human connected the
	    Caller is always a bot (one that has not called yet first).
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

local BotBrain = require(script.Parent.BotBrain)
local BotRig = require(script.Parent.BotRig)
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
local BOT_BUILD_TIMEOUT = 8 -- engine-built bot bodies that take longer are replaced by block rigs
local BOTS_FOLDER = "Bots" -- folder in the match room holding the bot rigs
local STAND_RADIUS = 7 -- participants without a Seat stand on a ring this far from the room centre
local WAVE_CHANCE = 0.5 -- a bot waves hello during INTRO
local WAVE_DELAY = { 0.4, 2.0 }
local POINT_CHANCE = 0.6 -- a bot Caller points at an answer it rules WRONG
local LAUGH_CHANCE = 0.35 -- one bot chuckles when somebody else is eliminated
local LAUGH_DELAY = { 0.3, 1.0 }

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
	player: Player?, -- nil for an AI detective
	isBot: boolean,
	rig: BotRig.BotRig?, -- bots: the body in the room (nil until built / after cleanup)
	userId: number, -- bots: negative, unique
	name: string, -- DisplayName at match start / bot name
	index: number, -- position in Match.records (clockwise order)
	seat: number, -- SeatAnchor number in the room
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
	players: { Player }, -- the humans
	botIds: { number }, -- one negative userId per AI detective
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

	records: { PlayerRecord }, -- clockwise (sorted by seat); record.index = position
	byPlayer: { [Player]: PlayerRecord }, -- humans only
	bySeat: { [number]: PlayerRecord },
	hasBots: boolean,
	botFolder: Folder?,
	botsPending: number, -- engine bot bodies still being built
	botThreads: { thread }, -- bot think / animation threads (cancelled at cleanup)

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

local function newRecord(userId: number, name: string, player: Player?): PlayerRecord
	return {
		player = player,
		isBot = player == nil,
		rig = nil,
		userId = userId,
		name = name,
		index = 0,
		seat = 0,
		status = "Active",
		roundWins = 0,
		acceptedCount = 0,
		wasCaller = false,
		reseatPending = false,
		lobbyTarget = nil,
		characterConnection = nil,
	}
end

local function shuffle<T>(list: { T }, rng: Random)
	for index = #list, 2, -1 do
		local swap = rng:NextInteger(1, index)
		list[index], list[swap] = list[swap], list[index]
	end
end

-- `count` distinct bot names: Config.Bots.Names shuffled; numbered repeats
-- only if there are more bots than names.
local function botNames(rng: Random, count: number): { string }
	local pool = table.clone(Config.Bots.Names)
	if #pool == 0 then
		pool = { "Det. Unknown" }
	end
	shuffle(pool, rng)
	local names: { string } = table.create(count)
	for index = 1, count do
		local base = pool[(index - 1) % #pool + 1]
		local lap = (index - 1) // #pool
		names[index] = if lap == 0 then base else `{base} {lap + 1}`
	end
	return names
end

function Match.new(params: MatchParams): Match
	local rng = Random.new()
	local room = RoomController.new(params.room, params.slot)
	local records: { PlayerRecord } = {}
	local byPlayer: { [Player]: PlayerRecord } = {}
	for _, player in params.players do
		local record = newRecord(player.UserId, player.DisplayName, player)
		table.insert(records, record)
		byPlayer[player] = record
	end

	-- Bots only fill seats that exist (a smaller template never stacks bots).
	local botCount = #params.botIds
	local seatCount = room:getSeatCount()
	if seatCount > 0 then
		local free = math.max(seatCount - #records, 0)
		if botCount > free then
			warn(`[Match {params.room.Name}] only {seatCount} seats: {botCount - free} AI detective(s) left out`)
			botCount = free
		end
	end
	local names = botNames(rng, botCount)
	for index = 1, botCount do
		table.insert(records, newRecord(params.botIds[index], names[index], nil))
	end

	-- Humans and bots shuffled together, spread evenly around the table.
	shuffle(records, rng)
	local seats = room:spreadSeats(#records)
	local bySeat: { [number]: PlayerRecord } = {}
	for index, record in records do
		record.index = index
		record.seat = seats[index]
		bySeat[record.seat] = record
	end

	local self: MatchData = {
		id = params.id,
		slot = params.slot,
		queueIndex = params.queueIndex,
		roomName = params.room.Name,
		room = room,
		params = params,
		rng = rng,

		records = records,
		byPlayer = byPlayer,
		bySeat = bySeat,
		hasBots = botCount > 0,
		botFolder = nil,
		botsPending = 0,
		botThreads = {},

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

-- Bots are always connected; humans until they leave.
function Match.isConnected(_self: Match, record: PlayerRecord): boolean
	if record.status == "Left" then
		return false
	end
	local player = record.player
	if player then
		return player.Parent ~= nil
	end
	return record.isBot
end

-- Connected participants, bots included (what MinPlayersToContinue counts).
function Match.countConnected(self: Match): number
	local count = 0
	for _, record in self.records do
		if self:isConnected(record) then
			count += 1
		end
	end
	return count
end

function Match.countConnectedHumans(self: Match): number
	local count = 0
	for _, record in self.records do
		if not record.isBot and self:isConnected(record) then
			count += 1
		end
	end
	return count
end

-- The humanoid that represents `record` in the world right now, if any.
function Match.humanoidOf(_self: Match, record: PlayerRecord): Humanoid?
	local player = record.player
	if player then
		return CharacterUtil.getHumanoid(player)
	end
	local rig = record.rig
	return if rig then rig:getHumanoid() else nil
end

-- The participant whose character owns `humanoid`, if any.
function Match.recordOfHumanoid(self: Match, humanoid: Humanoid): PlayerRecord?
	local character = humanoid.Parent
	if character and character:IsA("Model") then
		local player = Players:GetPlayerFromCharacter(character)
		if player then
			return self.byPlayer[player]
		end
	end
	for _, record in self.records do
		local rig = record.rig
		if rig and rig.humanoid == humanoid then
			return record
		end
	end
	return nil
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
			isBot = record.isBot,
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
		local player = record.player
		if player and self:isConnected(record) then
			Remotes.MatchSnapshot:FireClient(player, snapshot)
		end
	end
end

function Match.fireEvent(self: Match, event: Remotes.MatchEvent)
	for _, record in self.records do
		local player = record.player
		if player and self:isConnected(record) then
			Remotes.MatchEvent:FireClient(player, event)
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
	self:driveBots(newState)
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
	-- Bots never play to an empty house: no humans left means CLEANUP now.
	if self:countConnectedHumans() == 0 then
		self:log("no humans left: cleanup")
		self:cleanup()
		return
	end
	if state == "GAME_END" then
		if self:timeUp(now) then
			self:cleanup()
		end
		return
	end

	local connected = self:countConnected()
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
		local player = record.player
		if player then
			-- Nobody wanders out of the elevator while the room streams in.
			CharacterUtil.lockMovement(player)
			record.characterConnection = player.CharacterAdded:Connect(function(character: Model)
				self:onCharacterAdded(record, character)
			end)
		end
	end

	local botsStarted = serverNow()
	self:startBotBodies()
	self:streamRoom()
	self:waitForCharacters()
	self:finishBotBodies(botsStarted + BOT_BUILD_TIMEOUT)

	self.totalRounds = if Config.Match.RoundsPerMatch > 0
		then Config.Match.RoundsPerMatch
		else math.max(self:countConnectedHumans(), 1)

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
		local player = record.player
		if player and record.status ~= "Left" then
			pending += 1
			local target = self:standPosition(record)
			task.spawn(function()
				local ok, err = pcall(function()
					player:RequestStreamAroundAsync(target, STREAM_TIMEOUT)
				end)
				if not ok then
					self:log(`stream request for {player.Name} failed: {err}`)
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

local function isMissing(record: PlayerRecord): boolean
	local player = record.player
	return player ~= nil and record.status ~= "Left" and not CharacterUtil.isAlive(player)
end

function Match.waitForCharacters(self: Match)
	local deadline = serverNow() + Config.Match.CharacterWaitSeconds
	while serverNow() < deadline do
		local missing = false
		for _, record in self.records do
			if isMissing(record) then
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
		if isMissing(record) then
			self:dropUnloaded(record)
		end
	end
end

-- A player whose character never appeared counts as Left and is handed back
-- to the lobby systems (they can queue again).
function Match.dropUnloaded(self: Match, record: PlayerRecord)
	local player = record.player
	if not player then
		return
	end
	warn(`[Match {self.roomName}] {player.Name} never loaded a character; treating as Left`)
	record.status = "Left"
	if record.characterConnection then
		record.characterConnection:Disconnect()
		record.characterConnection = nil
	end
	self.room:getModel():RemovePersistentPlayer(player)
	self.params.releasePlayer(player)
	CharacterUtil.unlockMovement(player)
	if player.Parent then
		Remotes.Notify:FireClient(player, "Couldn't load you into the interrogation room.", "Error")
	end
end

----------------------------------------------------------------------------
-- Bot bodies
----------------------------------------------------------------------------

-- Where a participant stands when not seated in a Seat (spawn point of a
-- bot body, fallback when the room has fewer seats than participants).
function Match.standPosition(self: Match, record: PlayerRecord): Vector3
	local seat = self.room:getSeat(record.seat)
	if seat then
		return seat.Position
	end
	local count = math.max(#self.records, 1)
	local angle = (record.index - 1) / count * 2 * math.pi
	return self.room:getOrigin() + Vector3.new(math.cos(angle) * STAND_RADIUS, 0, math.sin(angle) * STAND_RADIUS)
end

function Match.ensureBotFolder(self: Match): Folder
	local existing = self.botFolder
	if existing then
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = BOTS_FOLDER
	folder.Parent = self.room:getModel()
	self.botFolder = folder
	return folder
end

-- Starts building every bot's engine body in parallel (each call yields).
-- A body that arrives after its block-rig fallback or after cleanup is
-- destroyed on arrival.
function Match.startBotBodies(self: Match)
	if not self.hasBots then
		return
	end
	local folder = self:ensureBotFolder()
	for _, record in self.records do
		if record.isBot then
			self.botsPending += 1
			local description = BotRig.randomDescription(self.rng)
			task.spawn(function()
				local model = BotRig.modelFromDescription(description)
				self.botsPending -= 1
				if not model then
					return
				end
				if self.closed or record.rig ~= nil then
					model:Destroy()
					return
				end
				record.rig = BotRig.new(model, record.name, folder, CFrame.new(self:standPosition(record)))
			end)
		end
	end
end

-- Waits (until `deadline`) for the engine bodies, then gives every bot that
-- still has none a block rig. Never leaves a bot without a body.
function Match.finishBotBodies(self: Match, deadline: number)
	if not self.hasBots then
		return
	end
	while self.botsPending > 0 and serverNow() < deadline do
		task.wait(CHARACTER_POLL)
	end
	local folder = self:ensureBotFolder()
	for _, record in self.records do
		if record.isBot and record.rig == nil then
			local model = BotRig.blockModel(BotRig.randomDescription(self.rng))
			record.rig = BotRig.new(model, record.name, folder, CFrame.new(self:standPosition(record)))
		end
	end
end

function Match.animate(_self: Match, record: PlayerRecord, name: BotRig.AnimationName)
	local rig = record.rig
	if rig then
		rig:play(name)
	end
end

----------------------------------------------------------------------------
-- Character placement, respawns and the seat watchdog
----------------------------------------------------------------------------

function Match.sendToLounge(self: Match, record: PlayerRecord)
	local spawnPart = self.room:spectatorSpawnFor(record.userId)
	local target = if spawnPart then spawnPart.CFrame else nil
	if not target then
		warn(`[Match {self.roomName}] no spectator spawn for {record.name}`)
	end
	local player = record.player
	if player then
		if target then
			CharacterUtil.teleport(player, target)
		end
		CharacterUtil.unlockMovement(player)
		return
	end
	local rig = record.rig
	if rig then
		rig:teleport(target or CFrame.new(self:standPosition(record)))
	end
end

-- Puts a participant where their status says they belong: Active -> their
-- seat (movement locked), Eliminated -> the spectator lounge (free to walk).
function Match.placeRecord(self: Match, record: PlayerRecord)
	if record.status == "Active" then
		local seat = self.room:getSeat(record.seat)
		local player = record.player
		if player then
			CharacterUtil.lockMovement(player)
			if seat then
				CharacterUtil.seat(player, seat)
			else
				CharacterUtil.teleport(player, CFrame.new(self:standPosition(record)))
			end
			return
		end
		local rig = record.rig
		if rig then
			if seat then
				rig:seat(seat)
			else
				rig:teleport(CFrame.new(self:standPosition(record)))
			end
		end
	elseif record.status == "Eliminated" then
		self:sendToLounge(record)
	end
end

function Match.onCharacterAdded(self: Match, record: PlayerRecord, character: Model)
	local player = record.player
	if not player or self.closed or not self.seatingEnabled or record.status == "Left" then
		return
	end
	local root = CharacterUtil.waitForRoot(character, RESPAWN_ROOT_WAIT)
	if not root then
		return
	end
	task.wait(RESPAWN_SETTLE)
	if self.closed or not self.seatingEnabled or hasLeft(record) or player.Character ~= character then
		return
	end
	self:log(`{player.Name} respawned; placing ({record.status})`)
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
		local humanoid = self:humanoidOf(record)
		if seat and humanoid and seat.Occupant ~= humanoid then
			self:placeRecord(record)
		end
	end)
end

-- Seat watchdog: an active participant who stands up (jump, physics glitch)
-- is re-seated shortly after; anybody else sitting in a match seat is ejected.
function Match.onSeatOccupantChanged(self: Match, seatNumber: number, seat: Seat)
	if self.closed or not self.seatingEnabled then
		return
	end
	local owner = self.bySeat[seatNumber]
	local occupant = seat.Occupant
	if occupant then
		local ownerHumanoid = if owner and owner.status == "Active" then self:humanoidOf(owner) else nil
		if occupant == ownerHumanoid then
			return
		end
		CharacterUtil.unseatHumanoid(occupant)
		local intruderRecord = self:recordOfHumanoid(occupant)
		self:log(`ejected {if intruderRecord then intruderRecord.name else "a humanoid"} from seat {seatNumber}`)
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

-- Caller eligibility passes, most preferred first. With two or more humans:
-- humans who haven't called, then anyone who hasn't (bots), then humans,
-- then anyone. With one human (solo play): bots who haven't called, then
-- bots, then anyone (only if no bot is left, which cannot normally happen).
type CallerPass = (record: PlayerRecord) -> boolean

local MULTI_HUMAN_PASSES: { CallerPass } = {
	function(record)
		return not record.isBot and not record.wasCaller
	end,
	function(record)
		return not record.wasCaller
	end,
	function(record)
		return not record.isBot
	end,
	function(_record)
		return true
	end,
}
local SOLO_PASSES: { CallerPass } = {
	function(record)
		return record.isBot and not record.wasCaller
	end,
	function(record)
		return record.isBot
	end,
	function(_record)
		return true
	end,
}

function Match.chooseCaller(self: Match): PlayerRecord?
	local records = self.records
	local count = #records
	local passes: { CallerPass } = if self:countConnectedHumans() <= 1 then SOLO_PASSES else MULTI_HUMAN_PASSES
	local previous = self.caller
	for _, pass in passes do
		if not previous then
			-- Round 1: uniformly random among the preferred candidates.
			local candidates: { PlayerRecord } = {}
			for _, record in records do
				if self:isConnected(record) and pass(record) then
					table.insert(candidates, record)
				end
			end
			if #candidates > 0 then
				return candidates[self.rng:NextInteger(1, #candidates)]
			end
		else
			-- Later rounds: clockwise from the previous Caller (who comes last).
			for offset = 1, count do
				local record = records[(previous.index - 1 + offset) % count + 1]
				if self:isConnected(record) and pass(record) then
					return record
				end
			end
		end
	end
	return nil
end

-- Answerers in clockwise order starting with the participant LEFT of the
-- Caller (the next one around the table), wrapping around.
function Match.buildTurnOrder(self: Match): { PlayerRecord }
	local order: { PlayerRecord } = {}
	local caller = self.caller
	local count = #self.records
	local callerIndex = if caller then caller.index else 0
	for offset = 1, count do
		local record = self.records[(callerIndex - 1 + offset) % count + 1]
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
		if record.player and self:isConnected(record) then
			table.insert(connected, record)
		end
	end
	local targets = self.params.lobbyTargets(#connected)
	for index, record in connected do
		local target = targets[index]
		local player = record.player
		record.lobbyTarget = target
		if target and player then
			task.spawn(function()
				pcall(function()
					player:RequestStreamAroundAsync(target.Position, STREAM_TIMEOUT)
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
-- AI detectives: thinking and acting
----------------------------------------------------------------------------

-- Drops finished threads from the tracking list.
function Match.pruneBotThreads(self: Match)
	local threads = self.botThreads
	for index = #threads, 1, -1 do
		if coroutine.status(threads[index]) == "dead" then
			table.remove(threads, index)
		end
	end
end

-- Runs `act` in a tracked thread after `seconds`, but only if the match is
-- still open and `stillValid()` (state / round / turn identity) still holds
-- when the wait is over.
function Match.botAfter(self: Match, seconds: number, stillValid: () -> boolean, act: () -> ())
	self:pruneBotThreads()
	local thread = task.spawn(function()
		task.wait(seconds)
		if self.closed or not stillValid() then
			return
		end
		act()
	end)
	table.insert(self.botThreads, thread)
end

function Match.cancelBotThreads(self: Match)
	local running = coroutine.running()
	for _, thread in self.botThreads do
		if thread ~= running and coroutine.status(thread) == "suspended" then
			task.cancel(thread)
		end
	end
	table.clear(self.botThreads)
end

-- Called after every transition: schedules whatever the bots do in `state`.
function Match.driveBots(self: Match, state: MatchState)
	if self.closed or not self.hasBots then
		return
	end
	if state == "INTRO" then
		for _, record in self.records do
			if record.isBot and self.rng:NextNumber() < WAVE_CHANCE then
				self:botAfter(BotBrain.inRange(self.rng, WAVE_DELAY), function()
					return self.state == "INTRO"
				end, function()
					self:animate(record, "Wave")
				end)
			end
		end
	elseif state == "CATEGORY_SELECTION" then
		local caller = self.caller
		if caller and caller.isBot then
			self:botPickCategory(caller)
		end
	elseif state == "PLAYING" then
		local turn = self.turn
		if turn and turn.record.isBot then
			self:botAnswer(turn)
		end
	elseif state == "JUDGING" then
		local caller = self.caller
		local judging = self.judging
		if caller and caller.isBot and judging and not self.autoJudge then
			self:botJudge(caller, judging)
		end
	elseif state == "ELIMINATION" then
		self:botReactToElimination()
	elseif state == "ROUND_END" then
		local winner = self.roundWinner
		if winner and winner.isBot then
			self:animate(winner, "Cheer")
		end
	elseif state == "GAME_END" then
		local winners: { number } = self.winnerUserIds or {}
		for _, userId in winners do
			for _, record in self.records do
				if record.isBot and record.userId == userId then
					self:animate(record, "Cheer")
				end
			end
		end
	end
end

function Match.botPickCategory(self: Match, caller: PlayerRecord)
	local round = self.round
	local now = serverNow()
	local delay = BotBrain.delayWithin(self.rng, Config.Bots.CategoryDelay, now, self.stateEndsAt or now)
	self:botAfter(delay, function()
		return self.state == "CATEGORY_SELECTION" and self.round == round and self.caller == caller
	end, function()
		self:submitCategoryFrom(caller, BotBrain.pickCategory(self.rng))
	end)
end

function Match.botAnswer(self: Match, turn: Turn)
	local record = turn.record
	local delay = BotBrain.answerWait(self.rng, serverNow(), turn.startsAt, turn.endsAt)
	self:botAfter(delay, function()
		return self.state == "PLAYING" and self.turn == turn and record.status == "Active"
	end, function()
		local text = BotBrain.chooseAnswer(self.rng, self.category, self.accepted, self.acceptedKeys)
		if text then
			self:submitAnswerFrom(record, turn.id, text)
		end
	end)
end

function Match.botJudge(self: Match, caller: PlayerRecord, judging: Judging)
	local delay = BotBrain.delayWithin(self.rng, Config.Bots.JudgeDelay, serverNow(), judging.deadline)
	self:botAfter(delay, function()
		return self.state == "JUDGING" and self.judging == judging and self.caller == caller and not self.autoJudge
	end, function()
		local verdict: Verdict = BotBrain.judge(self.rng, self.category, judging.answer)
		self:judgeAnswerFrom(caller, judging.turnId, verdict)
		if verdict == "Wrong" and self.rng:NextNumber() < POINT_CHANCE then
			self:animate(caller, "Point")
		end
	end)
end

-- Now and then one of the other bots chuckles at an elimination.
function Match.botReactToElimination(self: Match)
	local elimination = self.elimination
	if not elimination or self.rng:NextNumber() >= LAUGH_CHANCE then
		return
	end
	local candidates: { PlayerRecord } = {}
	for _, record in self.records do
		if record.isBot and record ~= elimination.record and record.status ~= "Left" then
			table.insert(candidates, record)
		end
	end
	if #candidates == 0 then
		return
	end
	local laugher = candidates[self.rng:NextInteger(1, #candidates)]
	self:botAfter(BotBrain.inRange(self.rng, LAUGH_DELAY), function()
		return self.state == "ELIMINATION"
	end, function()
		self:animate(laugher, "Laugh")
	end)
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
		if record.player and self:isConnected(record) and not record.lobbyTarget then
			table.insert(needTargets, record)
		end
	end
	local fresh = if #needTargets > 0 then self.params.lobbyTargets(#needTargets) else {}
	for index, record in needTargets do
		record.lobbyTarget = fresh[index]
	end

	for _, record in self.records do
		local player = record.player
		if player and self:isConnected(record) then
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

-- Ends the match for good. Order matters: bot threads stop first, then the
-- final CLEANUP snapshot (the clients switch back to lobby mode), the lobby
-- teleport, the membership release, the bot bodies, connections, the room
-- and finally the slot. Idempotent and safe to call from the crash handler.
function Match.cleanup(self: Match)
	if self.closed then
		return
	end
	self.closed = true -- stops the loop and makes every in-flight handler / bot thread bail out
	self.seatingEnabled = false
	self.turn = nil
	self.judging = nil
	self.musicStartTime = nil
	self:cancelBotThreads()

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
		local player = record.player
		if player then
			safely(self, "release player", function()
				self.params.releasePlayer(player)
			end)
		end
		local rig = record.rig
		if rig then
			record.rig = nil
			safely(self, "destroy bot", function()
				rig:destroy()
			end)
		end
	end
	for _, connection in self.connections do
		connection:Disconnect()
	end
	table.clear(self.connections)
	safely(self, "destroy room", function()
		self.room:destroy()
	end)
	self.botFolder = nil
	safely(self, "free slot", self.params.onClosed)
	self:log("closed")
end

----------------------------------------------------------------------------
-- Input (validated by MatchService for types; validated here for role,
-- state, turn and timing). Humans arrive through the remotes (the Player
-- wrappers); bots call the *From paths directly with the same checks.
-- Handlers only RECORD; the loop acts.
----------------------------------------------------------------------------

local function rejectInput(record: PlayerRecord, what: "Answer" | "Category", reason: string)
	local player = record.player
	if player and player.Parent then
		Remotes.InputRejected:FireClient(player, what, reason)
	end
end

-- Broadcast filtering for a participant's text. Bot text comes from the
-- server's own WordBank, so it is passed through without a (yielding) call.
local function filterFor(record: PlayerRecord, text: string): (boolean, string)
	local player = record.player
	if record.isBot or not player then
		return true, text
	end
	return TextFilter.forBroadcast(text, player.UserId)
end

function Match.submitCategory(self: Match, player: Player, text: string)
	local record = self.byPlayer[player]
	if record then
		self:submitCategoryFrom(record, text)
	end
end

function Match.submitCategoryFrom(self: Match, record: PlayerRecord, text: string)
	if self.closed or self.state ~= "CATEGORY_SELECTION" then
		return
	end
	local caller = self.caller
	if not caller or caller ~= record or caller.status == "Left" then
		return
	end
	if self.category ~= nil or self.pendingCategory ~= nil or self.categorySubmitting then
		return -- the category is final once set; one filter call at a time
	end

	local ok, cleanedOrReason = AnswerRules.validateCategory(text)
	if not ok then
		rejectInput(record, "Category", cleanedOrReason)
		return
	end

	local round = self.round
	self.categorySubmitting = true
	local filterOk, filtered = filterFor(record, cleanedOrReason)
	-- Anything may have happened while the filter yielded.
	if self.closed or self.round ~= round or self.state ~= "CATEGORY_SELECTION" then
		return
	end
	self.categorySubmitting = false

	if not filterOk then
		self.pendingCategory = { text = self:fallbackCategory(), notice = NOTICE_FILTER_CATEGORY }
	elseif AnswerRules.wasCensored(cleanedOrReason, filtered) then
		rejectInput(record, "Category", REJECT_CENSORED_CATEGORY)
	else
		self.pendingCategory = { text = filtered, notice = nil }
	end
end

function Match.submitAnswer(self: Match, player: Player, turnId: number, text: string)
	local record = self.byPlayer[player]
	if record then
		self:submitAnswerFrom(record, turnId, text)
	end
end

function Match.submitAnswerFrom(self: Match, record: PlayerRecord, turnId: number, text: string)
	local arrivedAt = serverNow()
	if self.closed or self.state ~= "PLAYING" then
		return
	end
	local turn = self.turn
	if not turn or turn.id ~= turnId or turn.record ~= record or record.status ~= "Active" then
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
		rejectInput(record, "Answer", cleanedOrReason)
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
	local filterOk, filtered = filterFor(record, cleaned)
	if self.closed or self.state ~= "PLAYING" or self.turn ~= turn then
		return -- the turn ended while we were filtering (left, voided, match over)
	end
	turn.submitting = false

	if not filterOk then
		turn.result = { kind = "Voided" }
		return
	end
	if AnswerRules.wasCensored(cleaned, filtered) then
		rejectInput(record, "Answer", REJECT_CENSORED_ANSWER)
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
	local record = self.byPlayer[player]
	if record then
		self:judgeAnswerFrom(record, turnId, verdict)
	end
end

function Match.judgeAnswerFrom(self: Match, record: PlayerRecord, turnId: number, verdict: Verdict)
	local arrivedAt = serverNow()
	if self.closed or self.state ~= "JUDGING" or self.autoJudge then
		return
	end
	local judging = self.judging
	if not judging or judging.turnId ~= turnId or judging.verdict ~= nil then
		return
	end
	local caller = self.caller
	if not caller or caller ~= record or caller.status == "Left" then
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
