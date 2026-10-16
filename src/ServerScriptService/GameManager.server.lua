--!strict
--[[
	GameManager  (Script)  ·  ServerScriptService/GameManager

	The authoritative round loop for CONCENTRATION 64.

	PHASES (broadcast with Remotes.PhaseChanged)
	  Lobby ─► Intermission ─► Seating ─► Chant ─► CategoryPick ─► Turns ─► RoundOver ─┐
	    ▲                                                                              │
	    └──────────────────────────────────────────────────────────────────────────────┘

	  Lobby         wait for Config.Players.MinToStart players
	  Intermission  countdown; Force Caller can still be armed
	  Seating       up to 4 players sit in the Interrogation Room; extra
	                players watch from the Spectator Lounge
	  Chant         "Concentration, sixty-four, no repeats, or hesitation…"
	                on a beat shared by every client (see Shared/Rhythm)
	  CategoryPick  the Caller: "I'll go first, to my left, the category is…"
	  Turns         clockwise from the Caller; each turn is a fixed number
	                of beats. A timeout ("hesitation") or a repeated word
	                fails the player; then the bribe offer; then the lounge.
	  RoundOver     last suspect standing wins (+1 saved Win)

	The server owns ALL game state. Clients only send requests (typing,
	answers, category, purchases), and every one of them is validated here.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Categories = require(Shared:WaitForChild("Categories"))
local Config = require(Shared:WaitForChild("Config"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local Rhythm = require(Shared:WaitForChild("Rhythm"))
local WordRules = require(Shared:WaitForChild("WordRules"))

local Server = script.Parent:WaitForChild("Server")
local MonetizationService = require(Server:WaitForChild("MonetizationService"))
local PlayerDataService = require(Server:WaitForChild("PlayerDataService"))
local RateLimiter = require(Server:WaitForChild("RateLimiter"))
local RoomService = require(Server:WaitForChild("RoomService"))
local TextFilterService = require(Server:WaitForChild("TextFilterService"))

local COLORS = RoomService.Colors

----------------------------------------------------------------------------
-- Types & state
----------------------------------------------------------------------------
type Phase = Remotes.Phase
type Status = Remotes.RosterStatus
type UsedWord = { display: string, by: string }

type Turn = {
	id: number,
	player: Player,
	startsAt: number,
	endsAt: number,
	turnNumber: number,
	result: ("Answered" | "Skipped" | "Timeout" | "Repeat" | "Left")?,
	word: string?,
	repeatOf: UsedWord?,
	processingSince: number?, -- an answer is being filtered; don't time out mid-check
	lastDraftSeq: number,
}

type Bribe = {
	player: Player,
	endsAt: number,
	revived: boolean,
	declined: boolean,
}

type CategoryPick = {
	player: Player,
	offered: { number },
	endsAt: number,
	chosen: string?,
	custom: boolean,
	processing: boolean,
}

local state = {
	phase = "Lobby" :: Phase,
	phaseData = {} :: { [string]: any },
	roundNumber = 0,
	participants = {} :: { Player }, -- index = seat number
	status = {} :: { [Player]: Status },
	caller = nil :: Player?,
	lastCallerUserId = nil :: number?,
	category = nil :: string?,
	usedWords = {} :: { [string]: UsedWord }, -- canonicalKey → first use
	sync = nil :: Rhythm.Sync?,
	turn = nil :: Turn?,
	bribe = nil :: Bribe?,
	pick = nil :: CategoryPick?,
	benchedLastRound = {} :: { [number]: boolean }, -- userIds that sat out; they get priority next round
}

local turnCounter = 0

----------------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------------
local function now(): number
	return Workspace:GetServerTimeNow()
end

local function waitUntil(t: number)
	local delay = t - now()
	if delay > 0 then
		task.wait(delay)
	end
end

local function log(...: any)
	if Config.Debug.Verbose then
		print("[GameManager]", ...)
	end
end

local function notify(player: Player?, message: string, kind: string?)
	if player then
		if player.Parent then
			Remotes.Notify:FireClient(player, message, kind or "Info")
		end
	else
		Remotes.Notify:FireAllClients(message, kind or "Info")
	end
end

local function shuffle<T>(list: { T }): { T }
	for i = #list, 2, -1 do
		local j = math.random(i)
		list[i], list[j] = list[j], list[i]
	end
	return list
end

local function isRoundPhase(phase: Phase): boolean
	return phase ~= "Lobby" and phase ~= "Intermission"
end

local function setPhase(phase: Phase, data: { [string]: any }?)
	state.phase = phase
	state.phaseData = data or {}
	log("Phase →", phase)
	Remotes.PhaseChanged:FireAllClients(phase, state.phaseData)
end

local function isInRound(player: Player): boolean
	local status = state.status[player]
	return status == "Active" or status == "Pending"
end

local function activeCount(): number
	local count = 0
	for _, player in state.participants do
		if isInRound(player) then
			count += 1
		end
	end
	return count
end

local function rosterPayload(): { Remotes.RosterEntry }
	local roster = {}
	for seat, player in state.participants do
		local status: Status = state.status[player] or "Left"
		table.insert(roster, {
			userId = player.UserId,
			name = player.DisplayName,
			seat = seat,
			status = status,
		})
	end
	return roster
end

local function broadcastRoster()
	Remotes.RosterChanged:FireAllClients(rosterPayload())
end

local function turnPayload(turn: Turn): Remotes.TurnInfo
	return {
		id = turn.id,
		userId = turn.player.UserId,
		name = turn.player.DisplayName,
		startsAt = turn.startsAt,
		endsAt = turn.endsAt,
		turnNumber = turn.turnNumber,
	}
end

local function minPlayers(): number
	if RunService:IsStudio() and Config.Players.AllowSoloInStudio then
		return 1
	end
	return Config.Players.MinToStart
end

-- Players who can be put into a round: data loaded and a living character.
local function readyPlayers(): { Player }
	local list = {}
	for _, player in Players:GetPlayers() do
		if PlayerDataService.get(player) and player.Character then
			table.insert(list, player)
		end
	end
	return list
end

-- (Re)start the shared metronome. Without `startTime` the new tempo starts
-- on the next beat of the old one, so the groove never stutters.
local function setTempo(bpm: number, startTime: number?)
	local anchor = startTime
	if not anchor then
		local current = state.sync
		anchor = if current then Rhythm.nextBeatTime(current, now() + 0.05) else now() + 0.5
	end
	state.sync = Rhythm.new(bpm, anchor :: number, Config.Rhythm.BeatsPerBar)
	Remotes.RhythmSync:FireAllClients(state.sync)
end

local function stopTempo()
	state.sync = nil
	Remotes.RhythmSync:FireAllClients(nil)
end

----------------------------------------------------------------------------
-- Character placement (spawns, respawns, late joiners)
----------------------------------------------------------------------------
local function placeCharacter(player: Player)
	if isRoundPhase(state.phase) then
		local seatIndex = table.find(state.participants, player)
		if seatIndex and isInRound(player) then
			RoomService.seat(player, seatIndex)
		else
			RoomService.sendToLounge(player)
		end
	elseif not RoomService.isNearLobby(player) then
		RoomService.sendToLobby(player)
	end
end

local function onCharacterAdded(player: Player, character: Model)
	character:WaitForChild("HumanoidRootPart", 10)
	task.wait() -- let the default spawn placement finish first
	if player.Character == character then
		placeCharacter(player)
	end
end

----------------------------------------------------------------------------
-- Elimination, bribes and skips
----------------------------------------------------------------------------
local function eliminate(player: Player, reason: string)
	state.status[player] = if player.Parent then "Eliminated" else "Left"
	Remotes.AnswerResult:FireAllClients({
		userId = player.UserId,
		name = player.DisplayName,
		result = "Eliminated",
		reason = reason,
	} :: Remotes.AnswerResult)
	broadcastRoster()
	RoomService.setTV({ footer = `{string.upper(player.DisplayName)} → SPECTATOR LOUNGE`, bodyColor = COLORS.Red })
	if player.Parent then
		RoomService.sendToLounge(player) -- instantly behind the two-way mirror
	end
end

-- Opens the "Bribe the Detective?" window. Returns true if the player paid
-- (or spent a saved Revive token) in time.
local function runBribeWindow(player: Player, bribe: Bribe, reason: string): boolean
	state.bribe = bribe
	state.status[player] = "Pending"
	broadcastRoster()
	Remotes.BribeOffer:FireClient(player, { endsAt = bribe.endsAt, reason = reason } :: Remotes.BribeOffer)

	while not bribe.revived and not bribe.declined and player.Parent do
		-- Hold the window while the player is in the middle of paying.
		if now() >= bribe.endsAt and not MonetizationService.isPurchaseInFlight(player, "Revive") then
			break
		end
		task.wait()
	end

	state.bribe = nil
	if player.Parent then
		Remotes.BribeOffer:FireClient(player, nil)
	end
	if bribe.revived and player.Parent then
		state.status[player] = "Active"
		broadcastRoster()
		return true
	end
	return false
end

-- A player hesitated or repeated: offer the bribe, then eliminate.
local function handleFailure(player: Player, turn: Turn)
	local reason: Remotes.AnswerResultKind = if turn.result == "Repeat" then "Repeat" else "Timeout"
	local canBribe = player.Parent ~= nil and MonetizationService.isProductEnabled("Revive")
	local bribe: Bribe? = if canBribe
		then { player = player, endsAt = now() + Config.Bribe.WindowSeconds, revived = false, declined = false }
		else nil

	local repeatOf = turn.repeatOf
	Remotes.AnswerResult:FireAllClients({
		userId = player.UserId,
		name = player.DisplayName,
		result = reason,
		word = if repeatOf then repeatOf.display else nil,
		saidBy = if repeatOf then repeatOf.by else nil,
		bribeEndsAt = if bribe then bribe.endsAt else nil,
	} :: Remotes.AnswerResult)

	RoomService.setTV({
		body = if reason == "Repeat" and repeatOf then `REPEAT! "{string.upper(repeatOf.display)}"` else "HESITATION!",
		bodyColor = COLORS.Red,
		footer = if bribe then `{string.upper(player.DisplayName)} IS BRIBING THE DETECTIVE…` else "",
	})

	if bribe then
		if runBribeWindow(player, bribe, reason) then
			Remotes.AnswerResult:FireAllClients({
				userId = player.UserId,
				name = player.DisplayName,
				result = "Revived",
			} :: Remotes.AnswerResult)
			RoomService.setTV({ body = "BRIBE ACCEPTED", bodyColor = COLORS.Amber, footer = `{string.upper(player.DisplayName)} STAYS IN` })
			return
		end
	end

	eliminate(player, reason)
end

local function trySkip(player: Player): boolean
	local turn = state.turn
	if turn and turn.player == player and turn.result == nil then
		turn.result = "Skipped"
		return true
	end
	return false
end

local function tryRevive(player: Player): boolean
	local bribe = state.bribe
	if bribe and bribe.player == player and not bribe.revived and not bribe.declined then
		bribe.revived = true
		return true
	end
	return false
end

----------------------------------------------------------------------------
-- Phase: Lobby / Intermission
----------------------------------------------------------------------------
local function runLobby()
	setPhase("Lobby", { needed = minPlayers() })
	RoomService.setTV({ header = "CONCENTRATION 64", speaker = "", body = "AWAITING SUSPECTS", footer = "", bodyColor = COLORS.Paper })

	while true do
		local count = #readyPlayers()
		if count >= minPlayers() then
			local endsAt = now() + Config.Timing.IntermissionSeconds
			setPhase("Intermission", { endsAt = endsAt })
			local aborted = false
			while now() < endsAt do
				if #readyPlayers() < minPlayers() then
					aborted = true
					break
				end
				RoomService.setBoard(`NEXT CASE IN {math.ceil(endsAt - now())}`)
				task.wait(0.25)
			end
			if not aborted then
				return
			end
			setPhase("Lobby", { needed = minPlayers() })
		end
		RoomService.setBoard(`WAITING FOR SUSPECTS  {count}/{minPlayers()}`)
		task.wait(0.5)
	end
end

----------------------------------------------------------------------------
-- Phase: Seating
----------------------------------------------------------------------------
-- Pick up to MaxActive players. Priority: armed Force Caller (in purchase
-- order), then players who sat out last round, then random.
local function chooseParticipants(): ({ Player }, { Player })
	local pool = shuffle(readyPlayers())
	local function priority(player: Player): number
		local rank = MonetizationService.armedRank(player)
		if rank then
			return rank
		end
		return if state.benchedLastRound[player.UserId] then 1000 else 2000
	end
	table.sort(pool, function(a, b)
		return priority(a) < priority(b)
	end)

	local maxSeats = math.min(Config.Players.MaxActive, RoomService.seatCount())
	local active, benched = {}, {}
	for index, player in pool do
		table.insert(if index <= maxSeats then active else benched, player)
	end
	return shuffle(active), benched
end

local function runSeating(): boolean
	local participants, benched = chooseParticipants()
	if #participants == 0 then
		return false
	end

	state.participants = participants
	table.clear(state.status)
	for _, player in participants do
		state.status[player] = "Active"
	end
	table.clear(state.benchedLastRound)
	for _, player in benched do
		state.benchedLastRound[player.UserId] = true
	end

	-- Roster first so clients pick the right camera when the phase changes.
	broadcastRoster()
	setPhase("Seating", { endsAt = now() + Config.Timing.SeatingSeconds, round = state.roundNumber })

	for seat, player in participants do
		RoomService.seat(player, seat)
	end
	for _, player in Players:GetPlayers() do
		if not state.status[player] then
			RoomService.sendToLounge(player)
			notify(player, "The room is full. Watch from the lounge, you're first in next round!", "Info")
		end
	end

	RoomService.setTV({ header = `CASE #{state.roundNumber}`, speaker = "", body = "TAKE YOUR SEATS", footer = "", bodyColor = COLORS.Paper })
	task.wait(Config.Timing.SeatingSeconds)
	return activeCount() > 0
end

----------------------------------------------------------------------------
-- Phase: Chant
----------------------------------------------------------------------------
local function chooseCaller(): Player?
	-- 1) A Force Caller holder who is seated (first come, first served).
	for _, player in MonetizationService.armedPlayers() do
		if isInRound(player) then
			MonetizationService.setForceCallerArmed(player, false)
			if MonetizationService.consumeToken(player, "ForceCaller") then
				notify(player, "Force Caller used: you're calling this case!", "Success")
				return player
			end
		end
	end

	-- 2) Otherwise random, avoiding last round's Caller when possible.
	local candidates = {}
	for _, player in state.participants do
		if isInRound(player) and player.UserId ~= state.lastCallerUserId then
			table.insert(candidates, player)
		end
	end
	if #candidates == 0 then
		for _, player in state.participants do
			if isInRound(player) then
				table.insert(candidates, player)
			end
		end
	end
	return if #candidates > 0 then candidates[math.random(#candidates)] else nil
end

local function runChant(caller: Player)
	local choices = Config.Rhythm.StartBpmChoices
	local bpm = choices[math.random(#choices)]
	setTempo(bpm, now() + 0.75)
	local sync = state.sync :: Rhythm.Sync

	local countIn = Config.Rhythm.CountInBeats
	setPhase("Chant", {
		callerUserId = caller.UserId,
		callerName = caller.DisplayName,
		countIn = countIn,
		bpm = bpm,
	})
	RoomService.setTV({ header = "CONCENTRATION 64", speaker = `{bpm} BPM`, body = "READY…", footer = "", bodyColor = COLORS.Paper })

	-- Mirror the chant onto the TV once per bar (clients animate every beat themselves).
	local total = Rhythm.chantLength(countIn)
	for beat = countIn, total - 1, 4 do
		waitUntil(Rhythm.timeOfBeat(sync, beat))
		local frame = Rhythm.chantFrame(beat, countIn)
		local syllables = frame.syllables
		if syllables then
			local isCaller = frame.kind == "Caller"
			RoomService.setTV({
				speaker = if isCaller then `CALLER: {caller.DisplayName}` else "",
				body = table.concat(syllables, " "),
				bodyColor = if isCaller then COLORS.Amber else COLORS.Paper,
			})
		end
	end
	waitUntil(Rhythm.timeOfBeat(sync, total))
end

----------------------------------------------------------------------------
-- Phase: CategoryPick
----------------------------------------------------------------------------
local function sendCategoryPrompt(pick: CategoryPick)
	local options = {}
	for _, index in pick.offered do
		table.insert(options, { index = index, name = Categories[index] })
	end
	Remotes.CategoryPrompt:FireClient(pick.player, {
		options = options,
		endsAt = pick.endsAt,
		canCustom = MonetizationService.hasCustomCategory(pick.player),
		customEnabled = MonetizationService.isCustomCategoryEnabled(),
	} :: Remotes.CategoryPrompt)
end

local function runCategoryPick(caller: Player): (string, boolean)
	local indices = {}
	for index = 1, #Categories do
		indices[index] = index
	end
	shuffle(indices)
	local offered = {}
	for i = 1, math.min(Config.Category.ChoicesOffered, #indices) do
		offered[i] = indices[i]
	end

	local pick: CategoryPick = {
		player = caller,
		offered = offered,
		endsAt = now() + Config.Timing.CategoryPickSeconds,
		chosen = nil,
		custom = false,
		processing = false,
	}
	state.pick = pick
	setPhase("CategoryPick", { callerUserId = caller.UserId, callerName = caller.DisplayName, endsAt = pick.endsAt })
	RoomService.setTV({ speaker = `CALLER: {caller.DisplayName}`, body = "THE CATEGORY IS…", footer = "CHOOSING…", bodyColor = COLORS.Amber })

	if caller.Parent then
		sendCategoryPrompt(pick)
	end
	while caller.Parent and not pick.chosen and (now() < pick.endsAt or pick.processing) do
		task.wait(0.1)
	end
	state.pick = nil
	if caller.Parent then
		Remotes.CategoryPrompt:FireClient(caller, nil)
	end

	local chosen = pick.chosen
	if chosen then
		return chosen, pick.custom
	end
	notify(nil, "The Caller hesitated, so the Detective picked the category!", "Info")
	return Categories[offered[math.random(#offered)]], false
end

----------------------------------------------------------------------------
-- Phase: Turns
----------------------------------------------------------------------------
local function turnBeats(sync: Rhythm.Sync): number
	local minimumBeats = math.ceil(Config.Turn.MinSeconds / Rhythm.interval(sync))
	return math.max(Config.Turn.Beats, minimumBeats)
end

local function runTurn(player: Player, turnNumber: number): Turn
	local sync = state.sync :: Rhythm.Sync
	turnCounter += 1

	local startsAt = Rhythm.nextBeatTime(sync, now() + 0.05) -- every turn opens on a beat
	local turn: Turn = {
		id = turnCounter,
		player = player,
		startsAt = startsAt,
		endsAt = startsAt + turnBeats(sync) * Rhythm.interval(sync),
		turnNumber = turnNumber,
		lastDraftSeq = 0,
	}
	state.turn = turn
	TextFilterService.resetDraft(player)

	Remotes.TurnStarted:FireAllClients(turnPayload(turn))
	RoomService.setTV({ speaker = `SUSPECT: {player.DisplayName}`, body = "", cursor = true, footer = "THINKING…", bodyColor = COLORS.Paper })

	local grace = Config.Timing.LatencyGraceSeconds
	while turn.result == nil do
		if player.Parent == nil then
			turn.result = "Left"
			break
		end
		local processingSince = turn.processingSince
		local checking = processingSince ~= nil and now() - processingSince < 5
		if now() > turn.endsAt + grace and not checking and not MonetizationService.isPurchaseInFlight(player, "SkipTurn") then
			turn.result = "Timeout"
		end
		task.wait()
	end

	state.turn = nil
	return turn
end

local function runTurns(order: { Player }, startedWith: number)
	setPhase("Turns", { category = state.category })

	-- With 2+ players the last one standing wins. A solo Studio test runs
	-- until you fail.
	local stopAt = if startedWith >= 2 then 1 else 0
	local index = 0
	local turnsTaken = 0

	while activeCount() > stopAt and turnsTaken < Config.Turn.MaxTurnsPerRound do
		index += 1
		if index > #order then
			-- Full lap around the table: speed up the beat.
			index = 1
			local sync = state.sync :: Rhythm.Sync
			local faster = math.min(sync.bpm + Config.Rhythm.BpmIncreasePerLap, Config.Rhythm.MaxBpm)
			if faster > sync.bpm then
				setTempo(faster)
				notify(nil, `The beat speeds up! {faster} BPM`, "Info")
			end
		end

		local player = order[index]
		if state.status[player] == "Active" then
			turnsTaken += 1
			local turn = runTurn(player, turnsTaken)
			local result = turn.result

			if result == "Answered" then
				local word = turn.word :: string
				Remotes.AnswerResult:FireAllClients({
					userId = player.UserId,
					name = player.DisplayName,
					result = "Accepted",
					word = word,
				} :: Remotes.AnswerResult)
				RoomService.setTV({ body = string.upper(word), bodyColor = COLORS.Green, footer = "✓ CLEARED" })
			elseif result == "Skipped" then
				Remotes.AnswerResult:FireAllClients({
					userId = player.UserId,
					name = player.DisplayName,
					result = "Skipped",
				} :: Remotes.AnswerResult)
				RoomService.setTV({ body = "SKIPPED", bodyColor = COLORS.Blue, footer = "PAID THEIR WAY OUT" })
			elseif result == "Timeout" or result == "Repeat" then
				handleFailure(player, turn)
			elseif result == "Left" then
				eliminate(player, "Left")
			end

			task.wait(Config.Turn.ResultHoldSeconds)
		end
	end
end

----------------------------------------------------------------------------
-- Phase: RoundOver + cleanup
----------------------------------------------------------------------------
local function finishRound(startedWith: number)
	local winner: Player? = nil
	for _, player in state.participants do
		if isInRound(player) and player.Parent then
			winner = player
			break
		end
	end

	local endsAt = now() + Config.Timing.RoundOverSeconds
	setPhase("RoundOver", {
		winnerUserId = if winner then winner.UserId else nil,
		winnerName = if winner then winner.DisplayName else nil,
		endsAt = endsAt,
	})
	stopTempo()

	if winner and startedWith >= 2 then
		PlayerDataService.addWin(winner)
	end
	RoomService.setTV({
		speaker = "",
		body = "CASE CLOSED",
		bodyColor = COLORS.Amber,
		footer = if winner then `WINNER: {string.upper(winner.DisplayName)}` else "NO SUSPECTS LEFT",
	})
	waitUntil(endsAt)
end

local function cleanupRound()
	state.turn = nil
	state.bribe = nil
	state.pick = nil
	state.caller = nil
	state.category = nil
	table.clear(state.usedWords)
	if state.sync then
		stopTempo()
	end

	-- Phase first, so respawning characters go to the lobby.
	state.participants = {}
	table.clear(state.status)
	setPhase("Lobby", { needed = minPlayers() })
	broadcastRoster()

	RoomService.clearSeats()
	for _, player in Players:GetPlayers() do
		RoomService.sendToLobby(player)
	end
end

local function runRound()
	state.roundNumber += 1
	table.clear(state.usedWords)
	state.category = nil

	if not runSeating() then
		return
	end

	local caller = chooseCaller()
	if not caller then
		return
	end
	state.caller = caller
	state.lastCallerUserId = caller.UserId

	runChant(caller)

	local category, custom = runCategoryPick(caller)
	state.category = category
	Remotes.CategoryChosen:FireAllClients({
		category = category,
		callerName = caller.DisplayName,
		custom = custom,
	} :: Remotes.CategoryChosen)
	RoomService.setTV({ header = `CATEGORY: {string.upper(category)}`, body = string.upper(category), footer = "NO REPEATS · NO HESITATION" })
	task.wait(1.5)

	-- Turn order: the Caller goes first, then to their left (seat order).
	local order = {}
	local start = table.find(state.participants, caller) or 1
	local count = #state.participants
	for offset = 0, count - 1 do
		table.insert(order, state.participants[(start - 1 + offset) % count + 1])
	end

	local startedWith = count
	runTurns(order, startedWith)
	finishRound(startedWith)
end

----------------------------------------------------------------------------
-- Remote handlers (ALL input is untrusted)
----------------------------------------------------------------------------
local allowTyping = RateLimiter.new(15, 15)
local allowSubmit = RateLimiter.new(4, 4)
local allowCategory = RateLimiter.new(2, 3)
local allowPurchase = RateLimiter.new(1, 2)

Remotes.TypingUpdate.OnServerEvent:Connect(function(player: Player, seq: any, text: any)
	local turn = state.turn
	if not turn or turn.player ~= player or turn.result ~= nil then
		return
	end
	if type(seq) ~= "number" or seq ~= seq or type(text) ~= "string" or #text > 200 then
		return
	end
	if seq <= turn.lastDraftSeq or not allowTyping(player) then
		return -- out of order (unreliable channel) or spam
	end
	turn.lastDraftSeq = seq

	local draft = WordRules.truncate(WordRules.clean(text), Config.Words.MaxLength)
	TextFilterService.submitDraft(player, draft, function(filtered: string)
		if state.turn == turn and turn.result == nil then
			RoomService.setTV({ body = string.upper(filtered), cursor = true, footer = "TYPING…" })
		end
	end)
end)

Remotes.SubmitAnswer.OnServerEvent:Connect(function(player: Player, answer: any)
	local turn = state.turn
	if not turn or turn.player ~= player or turn.result ~= nil or turn.processingSince then
		return
	end
	if type(answer) ~= "string" or #answer > 200 or not allowSubmit(player) then
		return
	end
	if now() > turn.endsAt + Config.Timing.LatencyGraceSeconds then
		return -- too late, the timeout will fire
	end

	local valid, cleanedOrReason = WordRules.validate(answer)
	if not valid then
		Remotes.AnswerRejected:FireClient(player, cleanedOrReason)
		return
	end

	-- "No repeats!" Checked on the raw, unfiltered text.
	local key = WordRules.canonicalKey(cleanedOrReason)
	local previous = state.usedWords[key]
	if previous then
		turn.repeatOf = previous
		turn.result = "Repeat"
		return
	end

	-- Filter before anyone else can see it (yields).
	turn.processingSince = now()
	local ok, filtered = TextFilterService.forBroadcast(cleanedOrReason, player.UserId)
	if state.turn ~= turn or turn.result ~= nil then
		return -- the turn ended while we were filtering (player left, etc.)
	end
	turn.processingSince = nil

	if not ok then
		Remotes.AnswerRejected:FireClient(player, "Couldn't check that word. Try again, quick!")
		return
	end
	if TextFilterService.wasCensored(cleanedOrReason, filtered) then
		Remotes.AnswerRejected:FireClient(player, "That word got filtered. Try another!")
		return
	end

	-- Another answer with the same key may have landed while we filtered.
	if state.usedWords[key] then
		turn.repeatOf = state.usedWords[key]
		turn.result = "Repeat"
		return
	end

	state.usedWords[key] = { display = filtered, by = player.DisplayName }
	turn.word = filtered
	turn.result = "Answered"
end)

Remotes.SubmitCategory.OnServerEvent:Connect(function(player: Player, kind: any, value: any)
	local pick = state.pick
	if not pick or pick.player ~= player or pick.chosen or pick.processing or not allowCategory(player) then
		return
	end

	if kind == "Preset" then
		if type(value) ~= "number" or not table.find(pick.offered, value) then
			return
		end
		pick.chosen = Categories[value]
		pick.custom = false
	elseif kind == "Custom" then
		if not MonetizationService.hasCustomCategory(player) then
			notify(player, "Custom categories need the Custom Category pass.", "Error")
			return
		end
		if type(value) ~= "string" or #value > 200 then
			return
		end
		local valid, cleanedOrReason = WordRules.validateCategory(value)
		if not valid then
			notify(player, cleanedOrReason, "Error")
			return
		end

		pick.processing = true
		local ok, filtered = TextFilterService.forBroadcast(cleanedOrReason, player.UserId)
		pick.processing = false
		if state.pick ~= pick or pick.chosen then
			return
		end
		if not ok or TextFilterService.wasCensored(cleanedOrReason, filtered) then
			notify(player, "That category got filtered. Try different words!", "Error")
			return
		end
		pick.chosen = filtered
		pick.custom = true
	end
end)

--[[
	Purchase validation. The client asks; the server checks the request makes
	sense RIGHT NOW. Then:
	  • the player owns a token  → spend it immediately (no Robux prompt)
	  • otherwise                → open the Robux prompt server-side; when the
	                               receipt lands, TokenGranted (below) applies it
]]
Remotes.RequestPurchase.OnServerEvent:Connect(function(player: Player, key: any)
	if type(key) ~= "string" or not allowPurchase(player) then
		return
	end

	if key == "SkipTurn" then
		local turn = state.turn
		if not turn or turn.player ~= player or turn.result ~= nil then
			notify(player, "You can only skip during your own turn.", "Error")
			return
		end
		if not MonetizationService.isProductEnabled("SkipTurn") then
			return
		end
		if MonetizationService.consumeToken(player, "SkipTurn") then
			trySkip(player)
		else
			MonetizationService.promptProduct(player, "SkipTurn")
		end
	elseif key == "Revive" then
		local bribe = state.bribe
		if not bribe or bribe.player ~= player or bribe.revived or bribe.declined then
			return
		end
		if MonetizationService.consumeToken(player, "Revive") then
			tryRevive(player)
		else
			MonetizationService.promptProduct(player, "Revive")
		end
	elseif key == "ForceCaller" then
		if isRoundPhase(state.phase) and isInRound(player) then
			notify(player, "Force Caller can be bought in the lobby or while spectating.", "Error")
			return
		end
		if not MonetizationService.isProductEnabled("ForceCaller") then
			return
		end
		if MonetizationService.isForceCallerArmed(player) then
			MonetizationService.setForceCallerArmed(player, false) -- toggle off; the token is kept
			notify(player, "Force Caller disarmed. Your token is saved.", "Info")
		elseif MonetizationService.getTokens(player, "ForceCaller") > 0 then
			MonetizationService.setForceCallerArmed(player, true)
			notify(player, "Force Caller armed: you'll call the next case!", "Success")
		else
			MonetizationService.promptProduct(player, "ForceCaller")
		end
	elseif key == "CustomCategory" then
		if MonetizationService.hasCustomCategory(player) then
			notify(player, "You already own Custom Categories!", "Info")
		elseif MonetizationService.isCustomCategoryEnabled() then
			MonetizationService.promptCustomCategory(player)
		end
	end
end)

Remotes.DeclineBribe.OnServerEvent:Connect(function(player: Player)
	local bribe = state.bribe
	if bribe and bribe.player == player and not bribe.revived then
		bribe.declined = true
	end
end)

-- A receipt was just saved. Apply it if it still fits the moment; otherwise
-- the token stays in the wallet for later.
MonetizationService.TokenGranted:Connect(function(player: Player, key: string)
	if key == "SkipTurn" then
		local turn = state.turn
		if turn and turn.player == player and turn.result == nil and MonetizationService.consumeToken(player, "SkipTurn") then
			trySkip(player)
			return
		end
		notify(player, "Skip Turn saved for later!", "Success")
	elseif key == "Revive" then
		local bribe = state.bribe
		if bribe and bribe.player == player and not bribe.revived and MonetizationService.consumeToken(player, "Revive") then
			tryRevive(player)
			return
		end
		notify(player, "Bribe saved for later!", "Success")
	elseif key == "ForceCaller" then
		if isRoundPhase(state.phase) and isInRound(player) then
			notify(player, "Force Caller saved. Arm it from the lobby!", "Success")
		else
			MonetizationService.setForceCallerArmed(player, true)
			notify(player, "Force Caller armed: you'll call the next case!", "Success")
		end
	end
end)

-- Bought the pass mid-pick? Re-send the picker with the custom box unlocked.
MonetizationService.CustomCategoryUnlocked:Connect(function(player: Player)
	notify(player, "Custom Categories unlocked!", "Success")
	local pick = state.pick
	if pick and pick.player == player and not pick.chosen then
		sendCategoryPrompt(pick)
	end
end)

Remotes.GetSnapshot.OnServerInvoke = function(player: Player): Remotes.Snapshot
	local turn = state.turn
	return {
		phase = state.phase,
		phaseData = state.phaseData,
		sync = state.sync,
		roster = rosterPayload(),
		category = state.category,
		turn = if turn then turnPayload(turn) else nil,
		wallet = MonetizationService.getWallet(player),
	}
end

----------------------------------------------------------------------------
-- Players
----------------------------------------------------------------------------
local function onPlayerAdded(player: Player)
	local leaderstats = Instance.new("Folder")
	leaderstats.Name = "leaderstats"
	local wins = Instance.new("IntValue")
	wins.Name = "Wins"
	wins.Parent = leaderstats
	leaderstats.Parent = player

	player.CharacterAdded:Connect(function(character)
		onCharacterAdded(player, character)
	end)
	if player.Character then
		task.spawn(onCharacterAdded, player, player.Character)
	end

	task.spawn(function()
		local profile = PlayerDataService.load(player)
		if profile and player.Parent then
			wins.Value = profile.Wins
			MonetizationService.onPlayerAdded(player)
		end
	end)
end

local function onPlayerRemoving(player: Player)
	if state.status[player] then
		state.status[player] = "Left"
	end
	local turn = state.turn
	if turn and turn.player == player and turn.result == nil then
		turn.result = "Left"
	end
	RoomService.release(player)
	PlayerDataService.release(player)
	if isRoundPhase(state.phase) then
		broadcastRoster()
	end
end

PlayerDataService.Changed:Connect(function(player: Player)
	local profile = PlayerDataService.get(player)
	local leaderstats = player:FindFirstChild("leaderstats")
	local wins = leaderstats and leaderstats:FindFirstChild("Wins")
	if profile and wins and wins:IsA("IntValue") then
		wins.Value = profile.Wins
	end
end)

----------------------------------------------------------------------------
-- Boot
----------------------------------------------------------------------------
RoomService.init()
MonetizationService.init()

Players.PlayerAdded:Connect(onPlayerAdded)
Players.PlayerRemoving:Connect(onPlayerRemoving)
for _, player in Players:GetPlayers() do
	task.spawn(onPlayerAdded, player)
end

while true do
	runLobby()
	local ok, err = xpcall(function(): string?
		runRound()
		return nil
	end, debug.traceback)
	if not ok then
		warn("[GameManager] Round crashed, resetting to lobby:\n", err)
	end
	cleanupRound()
end
