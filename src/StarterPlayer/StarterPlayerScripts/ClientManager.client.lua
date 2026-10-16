--!strict
--[[
	ClientManager  (LocalScript)  ·  StarterPlayerScripts/ClientManager

	Client bootstrap:
	  1. builds every screen once (one ScreenGui, ResetOnSpawn = false)
	  2. connects every remote handler, THEN catches up with GetState
	  3. mirrors server state into Client/State (queues, membership, match)
	  4. routes: decides which screens are visible from (state, role, status),
	     drives music / room FX / camera, and runs one RenderStepped loop that
	     ticks the visible widgets (each only writes when something changed)

	Snapshots are versioned per matchId: older versions are ignored, a new
	matchId replaces the current match, and matches that already ended are
	never resurrected by a late packet.
]]

local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local StarterGui = game:GetService("StarterGui")
local Workspace = game:GetService("Workspace")

local Names = require(ReplicatedStorage.Shared.Names)
local Remotes = require(ReplicatedStorage.Shared.Remotes)

local Client = script.Parent.Client
local AnswerBox = require(Client.AnswerBox)
local CameraController = require(Client.CameraController)
local CategoryPanel = require(Client.CategoryPanel)
local ChantText = require(Client.ChantText)
local EliminationOverlay = require(Client.EliminationOverlay)
local GameHUD = require(Client.GameHUD)
local InfoCard = require(Client.InfoCard)
local IntroOverlay = require(Client.IntroOverlay)
local JudgePanel = require(Client.JudgePanel)
local LobbyFX = require(Client.LobbyFX)
local Metronome = require(Client.Metronome)
local MusicController = require(Client.MusicController)
local QueueHUD = require(Client.QueueHUD)
local RoomFX = require(Client.RoomFX)
local SpectatorHUD = require(Client.SpectatorHUD)
local State = require(Client.State)
local Toasts = require(Client.Toasts)
local UIKit = require(Client.UIKit)
local VictoryScreen = require(Client.VictoryScreen)

type Snapshot = Remotes.MatchSnapshot
type MatchEvent = Remotes.MatchEvent

local localPlayer = Players.LocalPlayer

local ROOM_WAIT_SECONDS = 10
local VICTIM_CAMERA_HOLD = 1.1 -- the victim sees the jolt in the room before the lounge cams
local MUSIC_STATES: { [string]: boolean } = {
	COUNTDOWN = true,
	PLAYING = true,
	JUDGING = true,
	ELIMINATION = true,
}

----------------------------------------------------------------------------
-- Mirror bookkeeping
----------------------------------------------------------------------------
local currentVersion = -1
local lastStateName: string? = nil
local finishedMatches: { [string]: boolean } = {}
local roomToken = 0
local roomName: string? = nil
local spectatorCameraAfter = 0
local matchControlsApplied = false
local touchControlsBefore = true

----------------------------------------------------------------------------
-- UI construction
----------------------------------------------------------------------------
local gui = UIKit.screenGui("Concentration64", 10)

local function onTypingChanged(isTyping: boolean)
	State.typing = isTyping
	CameraController.setTyping(isTyping)
end

QueueHUD.mount(gui)
IntroOverlay.mount(gui)
InfoCard.mount(gui)
CategoryPanel.mount(gui, onTypingChanged)
GameHUD.mount(gui)
Metronome.mount(gui)
ChantText.mount(gui)
AnswerBox.mount(gui, onTypingChanged)
JudgePanel.mount(gui)
SpectatorHUD.mount(gui)
VictoryScreen.mount(gui)
EliminationOverlay.mount(gui)
Toasts.mount(gui)
UIKit.crtOverlay(gui)

----------------------------------------------------------------------------
-- Match-scoped player controls (touch thumbstick, reset button)
----------------------------------------------------------------------------
local resetEnabled: boolean? = nil
local function setResetEnabled(enabled: boolean)
	if resetEnabled == enabled then
		return
	end
	resetEnabled = enabled
	-- SetCore can fail until the CoreScripts register it; retry briefly.
	task.spawn(function()
		for _ = 1, 10 do
			if resetEnabled ~= enabled then
				return -- superseded by a newer request
			end
			if pcall(StarterGui.SetCore, StarterGui, "ResetButtonCallback", enabled) then
				return
			end
			task.wait(0.5)
		end
	end)
end

local function applyMatchControls(seated: boolean)
	if seated == matchControlsApplied then
		return
	end
	matchControlsApplied = seated
	if seated then
		touchControlsBefore = GuiService.TouchControlsEnabled
		GuiService.TouchControlsEnabled = false
	else
		GuiService.TouchControlsEnabled = touchControlsBefore
	end
end

----------------------------------------------------------------------------
-- Room resolution (StreamingEnabled may deliver the room late or never)
----------------------------------------------------------------------------
local function resolveRoom(name: string?)
	if name == roomName then
		return
	end
	roomName = name
	roomToken += 1
	local myToken = roomToken
	State.room = nil
	RoomFX.detach()
	CameraController.setRoom(nil)
	if not name then
		return
	end
	task.spawn(function()
		local folder = Workspace:WaitForChild(Names.ActiveMatches, ROOM_WAIT_SECONDS)
		local model = folder and folder:WaitForChild(name, ROOM_WAIT_SECONDS)
		if myToken ~= roomToken then
			return
		end
		if model and model:IsA("Model") then
			State.room = model
			RoomFX.attach(model)
			RoomFX.setSpectator(State.isSpectator())
			CameraController.setRoom(model)
		else
			warn(`[ClientManager] room {name} did not stream in; UI continues without room FX`)
		end
	end)
end

----------------------------------------------------------------------------
-- Routing
----------------------------------------------------------------------------
local function hideMatchScreens()
	IntroOverlay.hide()
	InfoCard.hide()
	CategoryPanel.hide()
	GameHUD.setVisible(false)
	Metronome.setVisible(false)
	ChantText.setVisible(false)
	AnswerBox.close()
	JudgePanel.setVisible(false)
	SpectatorHUD.setVisible(false)
	VictoryScreen.setVisible(false)
end

local function enterLobby()
	hideMatchScreens()
	EliminationOverlay.hide()
	MusicController.stop()
	resolveRoom(nil)
	CameraController.setMode("Lobby")
	applyMatchControls(false)
	setResetEnabled(true)
	LobbyFX.setActive(true)
	QueueHUD.setVisible(true)
	lastStateName = nil
end

local function cameraModeFor(stateName: string, spectator: boolean): CameraController.Mode
	if stateName == "INTRO" then
		return "Intro"
	elseif stateName == "ROUND_END" or stateName == "GAME_END" then
		return "Victory"
	elseif spectator and os.clock() >= spectatorCameraAfter then
		return "Spectator"
	end
	return "Room"
end

local function routeCamera(snapshot: Snapshot)
	local spectator = State.isSpectator()
	CameraController.setMode(cameraModeFor(snapshot.state, spectator))
	CameraController.setCallerFocus(snapshot.state == "JUDGING" and State.isCaller())
end

local function routeCards(snapshot: Snapshot, isCaller: boolean)
	local stateName = snapshot.state
	if stateName == "CALLER_SELECTION" then
		if isCaller then
			InfoCard.show("YOU ARE THE CALLER", "YOU NAME THE CATEGORY AND JUDGE EVERY ANSWER", snapshot.stateEndsAt, UIKit.Colors.Amber)
		else
			local name = string.upper(State.nameOf(snapshot.callerUserId))
			InfoCard.show(`{name} IS THE CALLER`, "ANSWER ON THE BEAT. NO REPEATS. NO HESITATION.", snapshot.stateEndsAt)
		end
	elseif stateName == "CATEGORY_SELECTION" and not isCaller then
		local name = string.upper(State.nameOf(snapshot.callerUserId))
		InfoCard.show(`{name} IS CHOOSING A CATEGORY...`, "STAND BY", snapshot.stateEndsAt)
	elseif stateName == "JUDGING" and (not isCaller or snapshot.autoJudge) then
		local judging = snapshot.judging
		local body = if judging then `{string.upper(State.nameOf(judging.userId))}: "{judging.answer}"` else nil
		local title = if snapshot.autoJudge then "AUTO-JUDGING..." else "CALLER IS JUDGING"
		InfoCard.show(title, body, if judging then judging.deadline else snapshot.stateEndsAt, UIKit.Colors.Amber)
	else
		InfoCard.hide()
	end
end

-- Decides every screen's visibility from (state, role, status).
local function route()
	local snapshot = State.snapshot
	if not snapshot or snapshot.state == "CLEANUP" then
		enterLobby()
		return
	end
	local stateName = snapshot.state
	local isCaller = State.isCaller()
	local spectator = State.isSpectator()
	local musicOn = MUSIC_STATES[stateName] == true

	if stateName ~= lastStateName then
		if stateName == "CATEGORY_SELECTION" then
			CategoryPanel.reset()
		end
		lastStateName = stateName
	end

	QueueHUD.setVisible(false)
	LobbyFX.setActive(false)
	applyMatchControls(State.me ~= nil and not spectator)
	setResetEnabled(false)
	resolveRoom(snapshot.roomName)
	RoomFX.setSpectator(spectator)
	MusicController.setStartTime(snapshot.musicStartTime)

	if stateName == "INTRO" then
		IntroOverlay.show((snapshot.slot or 0) + 1, string.upper(string.sub(snapshot.matchId or "", 1, 6)))
	else
		IntroOverlay.hide()
	end
	routeCards(snapshot, isCaller)

	if stateName == "CATEGORY_SELECTION" and isCaller then
		CategoryPanel.show()
	else
		CategoryPanel.hide()
	end

	-- During COUNTDOWN the chant owns the screen (and the category stays secret until the sting).
	GameHUD.setVisible(musicOn and stateName ~= "COUNTDOWN")
	GameHUD.update()
	Metronome.setVisible(musicOn and snapshot.musicStartTime ~= nil)
	ChantText.setVisible(stateName == "COUNTDOWN")

	local turn = snapshot.turn
	if State.isMyTurn() and turn and not spectator then
		AnswerBox.open(turn.id)
	else
		AnswerBox.close()
	end

	JudgePanel.setVisible(stateName == "JUDGING" and isCaller and not snapshot.autoJudge and snapshot.judging ~= nil)
	SpectatorHUD.setVisible(spectator and musicOn)
	VictoryScreen.setVisible(stateName == "ROUND_END" or stateName == "GAME_END")

	routeCamera(snapshot)
end

----------------------------------------------------------------------------
-- Snapshot intake
----------------------------------------------------------------------------
local function acceptSnapshot(snapshot: Snapshot): boolean
	if type(snapshot) ~= "table" or type(snapshot.matchId) ~= "string" then
		return false
	end
	if finishedMatches[snapshot.matchId] then
		return false -- a late packet from a match that already ended
	end
	local current = State.snapshot
	local version = if type(snapshot.version) == "number" then snapshot.version else 0
	if current and current.matchId == snapshot.matchId and version <= currentVersion then
		return false -- stale or duplicate
	end
	if current and current.matchId ~= snapshot.matchId then
		-- A newer match replaces the old one; never let the old one come back.
		finishedMatches[current.matchId] = true
		spectatorCameraAfter = 0
	end
	currentVersion = version
	return true
end

local function onSnapshot(snapshot: Snapshot)
	if not acceptSnapshot(snapshot) then
		return
	end
	if snapshot.state == "CLEANUP" then
		finishedMatches[snapshot.matchId] = true
		State.setSnapshot(nil)
		currentVersion = -1
	else
		State.setSnapshot(snapshot)
	end
	route()
end

----------------------------------------------------------------------------
-- One-shot events
----------------------------------------------------------------------------
local function onMatchEvent(event: MatchEvent)
	if type(event) ~= "table" or event.matchId ~= State.matchId() then
		return
	end
	local kind = event.kind
	if kind == "Eliminated" then
		RoomFX.pulseElimination()
		if event.userId == State.localUserId then
			EliminationOverlay.showVictim(event.reason, event.answer)
			CameraController.jolt()
			-- The render loop switches to the lounge cameras once this passes.
			spectatorCameraAfter = os.clock() + VICTIM_CAMERA_HOLD
		else
			EliminationOverlay.showOther(State.nameOf(event.userId), event.reason, event.answer)
		end
	elseif kind == "Accepted" then
		local who = if event.userId == State.localUserId then "YOUR ANSWER" else string.upper(State.nameOf(event.userId))
		Toasts.show(`{who} ACCEPTED: "{event.answer or ""}"`, "Good")
	elseif kind == "JudgeTimeout" then
		Toasts.show(event.text or "THE CALLER RAN OUT OF TIME - ANSWER ACCEPTED", "Warn")
	elseif kind == "Notice" then
		if event.text then
			Toasts.show(event.text, "Info")
		end
	elseif kind == "RoundWinner" then
		if event.userId == State.localUserId then
			Toasts.show("YOU WON THE ROUND", "Good")
		end
	elseif kind == "Victory" then
		local ids = event.userIds or {}
		if table.find(ids, State.localUserId) then
			Toasts.show(if #ids > 1 then "SHARED VICTORY" else "CASE CLOSED - YOU WIN", "Good")
		end
	end
end

----------------------------------------------------------------------------
-- Queue mirror
----------------------------------------------------------------------------
local function onQueueStatus(list: { Remotes.QueueStatus })
	if type(list) ~= "table" then
		return
	end
	table.clear(State.queues)
	for _, status in list do
		if type(status) == "table" and type(status.index) == "number" then
			State.queues[status.index] = status
		end
	end
	QueueHUD.update()
end

local function onQueueMembership(index: number?)
	State.queueIndex = if type(index) == "number" then index else nil
	QueueHUD.update()
end

local function onInputRejected(what: string, reason: string)
	local text = if type(reason) == "string" then reason else "Rejected."
	if what == "Answer" then
		AnswerBox.onRejected(text)
	elseif what == "Category" then
		CategoryPanel.onRejected(text)
	end
	Toasts.show(text, "Error")
end

local function onNotify(message: string, kind: string)
	if type(message) ~= "string" then
		return
	end
	Toasts.show(message, if kind == "Error" then "Error" else "Info")
end

----------------------------------------------------------------------------
-- Frame loop: ticks only the visible widgets; nothing rebuilds here.
----------------------------------------------------------------------------
local function onRenderStep()
	local beat = MusicController.currentBeat()
	QueueHUD.step()
	IntroOverlay.step()
	InfoCard.step()
	CategoryPanel.step()
	GameHUD.step()
	Metronome.step(beat)
	ChantText.step(beat)
	AnswerBox.step()
	JudgePanel.step()
	VictoryScreen.step()
	EliminationOverlay.step()
	Toasts.step()
	-- Time-based camera switch for an eliminated victim (after the jolt).
	local snapshot = State.snapshot
	if snapshot and spectatorCameraAfter > 0 and os.clock() >= spectatorCameraAfter then
		spectatorCameraAfter = 0
		routeCamera(snapshot)
	end
end

----------------------------------------------------------------------------
-- Boot: handlers first, then catch up.
----------------------------------------------------------------------------
Remotes.MatchSnapshot.OnClientEvent:Connect(onSnapshot)
Remotes.MatchEvent.OnClientEvent:Connect(onMatchEvent)
Remotes.QueueStatus.OnClientEvent:Connect(onQueueStatus)
Remotes.QueueMembership.OnClientEvent:Connect(onQueueMembership)
Remotes.InputRejected.OnClientEvent:Connect(onInputRejected)
Remotes.Notify.OnClientEvent:Connect(onNotify)

localPlayer.CharacterAdded:Connect(function()
	CameraController.onCharacterAdded()
	-- Thumbstick visibility is re-evaluated by the core scripts on spawn.
	if matchControlsApplied then
		GuiService.TouchControlsEnabled = false
	end
end)

RunService.RenderStepped:Connect(onRenderStep)
LobbyFX.start()
enterLobby()

task.spawn(function()
	local ok, result = pcall(function()
		return Remotes.GetState:InvokeServer()
	end)
	if not ok or type(result) ~= "table" then
		warn(`[ClientManager] GetState failed: {result}`)
		return
	end
	local state = result :: Remotes.ClientState
	if state.queues then
		onQueueStatus(state.queues)
	end
	onQueueMembership(state.queueIndex)
	if state.match then
		onSnapshot(state.match)
	end
end)
