--!strict
--[[
	ClientManager  (LocalScript)  ·  StarterPlayer/StarterPlayerScripts/ClientManager

	The client entry point. It builds the UI, owns a read-only MIRROR of the
	server's game state, and routes every RemoteEvent to the controller that
	draws it:

	    Remotes ──► ClientManager (state) ──► HUDController         header, timer, roster, banners
	                                    ├──► RhythmController    metronome, ticks, chant
	                                    ├──► CameraController    room / spectator cams, two-way mirror
	                                    ├──► AnswerController    bottom answer box, live typing, skip
	                                    ├──► CategoryController  the Caller's picker
	                                    └──► PurchaseController  bribe modal, Force Caller, prices

	The client decides NOTHING about the game. Timers are drawn from the
	server's deadlines using workspace:GetServerTimeNow(), so what you see
	matches what the server enforces.
]]

local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local StarterGui = game:GetService("StarterGui")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Remotes = require(Shared:WaitForChild("Remotes"))

local Client = script.Parent:WaitForChild("Client")
local UIKit = require(Client:WaitForChild("UIKit"))
local HUDController = require(Client:WaitForChild("HUDController"))
local RhythmController = require(Client:WaitForChild("RhythmController"))
local CameraController = require(Client:WaitForChild("CameraController"))
local AnswerController = require(Client:WaitForChild("AnswerController"))
local CategoryController = require(Client:WaitForChild("CategoryController"))
local PurchaseController = require(Client:WaitForChild("PurchaseController"))

local C = UIKit.Colors
local localPlayer = Players.LocalPlayer

type Role = "Lobby" | "Active" | "Spectator"

----------------------------------------------------------------------------
-- UI
----------------------------------------------------------------------------
local screen: ScreenGui = UIKit.create("ScreenGui", {
	Name = "Concentration64",
	ResetOnSpawn = false, -- keep the UI when the character respawns
	IgnoreGuiInset = false,
	ScreenInsets = Enum.ScreenInsets.CoreUISafeInsets, -- clear of notches and Roblox's top-bar buttons
	ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	Parent = localPlayer:WaitForChild("PlayerGui"),
})

local hud = HUDController.new(screen)
local rhythm = RhythmController.new(hud.metronomeHolder, hud)
local camera = CameraController.new()
local purchases = PurchaseController.new(screen)
local answer = AnswerController.new(screen, function()
	return purchases:labelFor("SkipTurn")
end)
local picker = CategoryController.new(screen, function()
	return purchases:priceLabel("CustomCategory")
end)

rhythm:onBeat(function(_beat: number, accent: boolean)
	camera:bump(accent)
end)
purchases:onChanged(function()
	answer:refreshSkip()
end)

-- One-shot sound effects.
local sfx: { [string]: Sound } = {}
for _, name in { "YourTurn", "Accepted", "Eliminated" } do
	local soundId = (Config.Audio :: any)[name]
	if type(soundId) == "string" and soundId ~= "" then
		local sound = Instance.new("Sound")
		sound.Name = "C64_" .. name
		sound.SoundId = soundId
		sound.Volume = 0.6
		sound.Parent = SoundService
		sfx[name] = sound
	end
end
local function playSfx(name: string)
	local sound = sfx[name]
	if sound then
		SoundService:PlayLocalSound(sound)
	end
end

----------------------------------------------------------------------------
-- Mirrored state
----------------------------------------------------------------------------
local state = {
	phase = "Lobby" :: Remotes.Phase,
	phaseData = {} :: { [string]: any },
	roster = {} :: { Remotes.RosterEntry },
	turn = nil :: Remotes.TurnInfo?,
	category = nil :: string?,
	bribeEndsAt = nil :: number?, -- someone's bribe window is open (drives the HUD timer)
	role = "Lobby" :: Role,
}

local function serverNow(): number
	return Workspace:GetServerTimeNow()
end

local function myEntry(): Remotes.RosterEntry?
	for _, entry in state.roster do
		if entry.userId == localPlayer.UserId then
			return entry
		end
	end
	return nil
end

local function computeRole(): Role
	if state.phase == "Lobby" or state.phase == "Intermission" then
		return "Lobby"
	end
	local entry = myEntry()
	if entry and (entry.status == "Active" or entry.status == "Pending") then
		return "Active"
	end
	return "Spectator"
end

local function refreshRoster()
	hud:setRoster(state.roster, if state.turn then state.turn.userId else nil, localPlayer.UserId)
end

-- Camera, controls and docks follow the player's role.
local function applyRole()
	local role: Role = computeRole()
	state.role = role

	local mode: CameraController.Mode = if role == "Active" then "Room" elseif role == "Spectator" then "Spectator" else "Default"
	camera:setMode(mode)
	hud:setSpectating(role == "Spectator")
	purchases:setLobbyVisible(role ~= "Active")
	answer:setVisible(role == "Active" and state.phase == "Turns")

	-- Seated players don't need the thumbstick or jump button; this frees
	-- the bottom of the phone screen for typing.
	local touchControls = role ~= "Active"
	if GuiService.TouchControlsEnabled ~= touchControls then
		GuiService.TouchControlsEnabled = touchControls
	end
	pcall(function()
		StarterGui:SetCore("ResetButtonCallback", role ~= "Active")
	end)
end

----------------------------------------------------------------------------
-- Remote handlers
----------------------------------------------------------------------------
local function onPhase(phase: Remotes.Phase, data: { [string]: any }?)
	local info: { [string]: any } = data or {}
	state.phase = phase
	state.phaseData = info

	if phase ~= "Chant" then
		rhythm:stopChant()
	end
	if phase ~= "CategoryPick" then
		picker:hide()
	end

	if phase == "Lobby" or phase == "Intermission" then
		state.turn = nil
		state.category = nil
		state.bribeEndsAt = nil
		rhythm:setIntensity(0)
		hud:hideBanner()
		hud:setCategory(nil)
		hud:setTurn(if phase == "Lobby" then "WAITING FOR SUSPECTS" else "NEXT CASE SOON", C.Paper)
		answer:disable()
		purchases:hideBribe()
	elseif phase == "Seating" then
		if computeRole() == "Active" then
			hud:setTurn("TAKE YOUR SEATS", C.Amber, true)
		else
			hud:setTurn("WATCHING FROM THE LOUNGE", C.Muted)
		end
		hud:showBanner(`CASE #{info.round or "?"}`, C.Amber, "The interrogation begins…", 2.2)
	elseif phase == "Chant" then
		rhythm:setIntensity(1)
		rhythm:startChant(info.countIn or Config.Rhythm.CountInBeats, info.callerName or "?")
		hud:setTurn("CONCENTRATION…", C.Amber)
	elseif phase == "CategoryPick" then
		rhythm:setIntensity(0.35)
		local isCaller = info.callerUserId == localPlayer.UserId
		hud:setTurn(if isCaller then "PICK THE CATEGORY!" else `{string.upper(info.callerName or "?")} IS PICKING…`, C.Amber, isCaller)
		if not isCaller then
			hud:showBanner("THE CATEGORY IS…", C.Amber, `🕵 {info.callerName or "?"} is the Caller`, math.huge)
		end
	elseif phase == "Turns" then
		rhythm:setIntensity(1)
	elseif phase == "RoundOver" then
		state.turn = nil
		state.bribeEndsAt = nil
		rhythm:setIntensity(0)
		answer:disable()
		purchases:hideBribe()
		local won = info.winnerUserId == localPlayer.UserId
		hud:setTurn("CASE CLOSED", C.Amber)
		hud:showBanner(
			if won then "YOU CRACKED THE CASE!" elseif info.winnerName then `{string.upper(info.winnerName)} WINS!` else "CASE CLOSED",
			if won then C.Green else C.Amber,
			"Back to the lobby…",
			5
		)
	end

	refreshRoster()
	applyRole()
end

local function onTurnStarted(turn: Remotes.TurnInfo)
	state.turn = turn
	state.bribeEndsAt = nil
	if turn.userId == localPlayer.UserId then
		answer:enable(turn)
		hud:setTurn("YOUR TURN!", C.Amber, true)
		playSfx("YourTurn")
	else
		answer:disable(`{turn.name} is answering…`)
		hud:setTurn(`{string.upper(turn.name)}'S TURN`, C.Paper, true)
	end
	refreshRoster()
	applyRole()
end

local function onAnswerResult(result: Remotes.AnswerResult)
	local isMe = result.userId == localPlayer.UserId
	local name = string.upper(result.name)

	if state.turn and state.turn.userId == result.userId then
		state.turn = nil
		if isMe then
			answer:disable()
		end
	end

	local kind = result.result
	if kind == "Accepted" then
		hud:showBanner(`✓ {string.upper(result.word or "")}`, C.Green, result.name, 1.1)
		playSfx("Accepted")
	elseif kind == "Skipped" then
		hud:showBanner("⏭ SKIPPED", C.Blue, `{result.name} paid their way out`, 1.1)
	elseif kind == "Timeout" or kind == "Repeat" then
		local headline = if kind == "Repeat" then `REPEAT! "{string.upper(result.word or "")}"` else "HESITATION!"
		local sub = if kind == "Repeat" and result.saidBy then `Already said by {result.saidBy}` else `{result.name} froze up`
		hud:showBanner(headline, C.Red, sub, 1.8)
		if result.bribeEndsAt then
			state.bribeEndsAt = result.bribeEndsAt
			hud:setTurn(if isMe then "BRIBE THE DETECTIVE?" else `{name} IS BRIBING…`, C.Amber, true)
		end
	elseif kind == "Revived" then
		state.bribeEndsAt = nil
		hud:showBanner("💰 BRIBE ACCEPTED", C.Amber, `{result.name} stays in the room!`, 1.6)
	elseif kind == "Eliminated" then
		state.bribeEndsAt = nil
		if result.reason == "Left" then
			hud:toast(`{result.name} fled the scene`, "Info")
		else
			hud:showBanner(`{name} ELIMINATED`, C.Red, if isMe then "To the spectator lounge…" else "Sent behind the two-way mirror", 1.8)
			playSfx("Eliminated")
		end
	end
	refreshRoster()
end

Remotes.PhaseChanged.OnClientEvent:Connect(onPhase)
Remotes.TurnStarted.OnClientEvent:Connect(onTurnStarted)
Remotes.AnswerResult.OnClientEvent:Connect(onAnswerResult)

Remotes.RhythmSync.OnClientEvent:Connect(function(sync: any)
	rhythm:setSync(sync, serverNow())
end)

Remotes.RosterChanged.OnClientEvent:Connect(function(roster: { Remotes.RosterEntry })
	state.roster = roster
	refreshRoster()
	applyRole()
end)

Remotes.AnswerRejected.OnClientEvent:Connect(function(reason: string)
	answer:reject(reason)
end)

Remotes.CategoryPrompt.OnClientEvent:Connect(function(prompt: Remotes.CategoryPrompt?)
	if prompt then
		picker:show(prompt)
	else
		picker:hide()
	end
end)

Remotes.CategoryChosen.OnClientEvent:Connect(function(info: Remotes.CategoryChosen)
	state.category = info.category
	picker:hide()
	hud:setCategory(info.category)
	hud:setTurn("NO REPEATS · NO HESITATION", C.Amber)
	hud:showBanner(
		string.upper(info.category),
		C.Amber,
		if info.custom then `Custom case from {info.callerName}` else `Called by {info.callerName}`,
		2.2
	)
end)

Remotes.BribeOffer.OnClientEvent:Connect(function(offer: Remotes.BribeOffer?)
	if offer then
		purchases:showBribe(offer, serverNow())
	else
		purchases:hideBribe()
	end
end)

Remotes.WalletChanged.OnClientEvent:Connect(function(wallet: Remotes.Wallet)
	purchases:setWallet(wallet)
end)

Remotes.Notify.OnClientEvent:Connect(function(message: string, kind: string?)
	hud:toast(message, kind)
end)

----------------------------------------------------------------------------
-- Per-frame: rhythm, timers, typing stream
----------------------------------------------------------------------------
RunService.RenderStepped:Connect(function()
	local t = serverNow()
	rhythm:update(t)
	answer:update()
	picker:update(t)
	purchases:update(t)

	-- Header timer: bribe fuse > current turn > phase countdown.
	local turn = state.turn
	local bribeEndsAt = state.bribeEndsAt
	local phaseEndsAt = state.phaseData.endsAt
	if bribeEndsAt then
		local remaining = bribeEndsAt - t
		hud:setTimer(remaining, remaining / Config.Bribe.WindowSeconds, true)
	elseif turn then
		local total = math.max(turn.endsAt - turn.startsAt, 0.001)
		local remaining = turn.endsAt - t
		hud:setTimer(math.min(remaining, total), remaining / total, remaining <= 2)
	elseif type(phaseEndsAt) == "number" and state.phase ~= "RoundOver" then
		hud:setTimer(phaseEndsAt - t, nil, false)
	else
		hud:setTimer(nil)
	end

	-- Lobby dock status line.
	if state.phase == "Lobby" then
		purchases:setLobbyStatus(`WAITING FOR SUSPECTS · {#Players:GetPlayers()}/{state.phaseData.needed or Config.Players.MinToStart}`)
	elseif state.phase == "Intermission" and type(phaseEndsAt) == "number" then
		purchases:setLobbyStatus(`NEXT CASE IN {math.max(0, math.ceil(phaseEndsAt - t))}`)
	elseif state.role == "Spectator" then
		purchases:setLobbyStatus("👁 WATCHING THE CASE")
	end
end)

----------------------------------------------------------------------------
-- Catch up with the server (late join / respawned UI)
----------------------------------------------------------------------------
task.spawn(function()
	local ok, snapshot = pcall(function()
		return Remotes.GetSnapshot:InvokeServer()
	end)
	if not ok or type(snapshot) ~= "table" then
		warn("[ClientManager] Could not fetch the game snapshot:", snapshot)
		return
	end
	local snap = snapshot :: Remotes.Snapshot

	state.roster = snap.roster
	rhythm:setSync(snap.sync, serverNow())
	if snap.wallet then
		purchases:setWallet(snap.wallet)
	end
	onPhase(snap.phase, snap.phaseData)
	if snap.category then
		state.category = snap.category
		hud:setCategory(snap.category)
	end
	if snap.turn then
		onTurnStarted(snap.turn)
	end
end)
