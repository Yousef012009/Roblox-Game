--!strict
--[[
	MusicController  (ModuleScript)  ·  StarterPlayerScripts/Client/MusicController

	Plays the match song in lock-step with the shared server clock.

	  songTime = Workspace:GetServerTimeNow() - musicStartTime

	The Sound loops its gameplay section natively (LoopRegion) and a 0.5 s
	watchdog snaps TimePosition back onto the timeline if it drifts more than
	Config.Music.ResyncThreshold. Late joiners land mid-song; the song is never
	restarted for an existing musicStartTime. With an empty SoundId the module
	runs in "silent mode": no audio, but currentBeat() still drives visuals.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage.Shared.Config)
local MusicTimeline = require(ReplicatedStorage.Shared.MusicTimeline)

local MusicController = {}

local RESYNC_INTERVAL = 0.5

local sound: Sound? = nil
local startTime: number? = nil
local generation = 0 -- bumps on every start/stop so stale scheduled threads quit
local resyncAccumulator = 0
local heartbeat: RBXScriptConnection? = nil
local muted = false

local function getSound(): Sound?
	if Config.Music.SoundId == "" then
		return nil
	end
	if not sound then
		local s = Instance.new("Sound")
		s.Name = "Concentration64Music"
		s.SoundId = Config.Music.SoundId
		s.Volume = if muted then 0 else Config.Music.Volume
		s.Looped = true
		s.PlaybackRegionsEnabled = true
		s.LoopRegion = NumberRange.new(MusicTimeline.LoopStart, MusicTimeline.LoopEnd)
		s.Parent = SoundService
		sound = s
	end
	return sound
end

local function songTimeNow(): number?
	local start = startTime
	if start == nil then
		return nil
	end
	return Workspace:GetServerTimeNow() - start
end

-- Waits (in its own thread) for the asset, bounded by LoadTimeoutSeconds.
local function waitLoaded(s: Sound, myGeneration: number): boolean
	local deadline = os.clock() + Config.Music.LoadTimeoutSeconds
	while not s.IsLoaded and os.clock() < deadline do
		if generation ~= myGeneration then
			return false
		end
		task.wait(0.1)
	end
	return s.IsLoaded and generation == myGeneration
end

local function beginPlayback(myGeneration: number)
	local s = getSound()
	if not s or not waitLoaded(s, myGeneration) then
		return
	end
	local songTime = songTimeNow()
	if songTime == nil then
		return
	end
	s.TimePosition = MusicTimeline.soundPosition(math.max(songTime, 0))
	s:Play()
end

-- Difference between where the Sound is and where it should be, folding the
-- loop so 23.7 s vs 13.2 s (just wrapped) counts as a tiny drift.
local function drift(actual: number, expected: number): number
	local diff = actual - expected
	if actual >= MusicTimeline.LoopStart and expected >= MusicTimeline.LoopStart then
		local half = MusicTimeline.LoopLength / 2
		if diff > half then
			diff -= MusicTimeline.LoopLength
		elseif diff < -half then
			diff += MusicTimeline.LoopLength
		end
	end
	return diff
end

local function onHeartbeat(dt: number)
	resyncAccumulator += dt
	if resyncAccumulator < RESYNC_INTERVAL then
		return
	end
	resyncAccumulator = 0
	local s = sound
	local songTime = songTimeNow()
	if not s or songTime == nil or songTime < 0 or not s.IsPlaying then
		return
	end
	local expected = MusicTimeline.soundPosition(songTime)
	if math.abs(drift(s.TimePosition, expected)) > Config.Music.ResyncThreshold then
		s.TimePosition = expected
	end
end

-- Sets (or clears with nil) the match's musicStartTime. Idempotent: the same
-- value again never restarts the song.
function MusicController.setStartTime(newStart: number?)
	if newStart == startTime then
		return
	end
	MusicController.stop()
	if newStart == nil then
		return
	end
	startTime = newStart
	generation += 1
	local myGeneration = generation
	heartbeat = RunService.Heartbeat:Connect(onHeartbeat)

	if not getSound() then
		return -- silent mode
	end
	local songTime = Workspace:GetServerTimeNow() - newStart
	-- Scheduled start (the server leads in by StartLeadInSeconds); loading
	-- happens inside beginPlayback, never blocking the caller.
	task.delay(math.max(0, -songTime), beginPlayback, myGeneration)
end

function MusicController.stop()
	generation += 1
	startTime = nil
	if heartbeat then
		heartbeat:Disconnect()
		heartbeat = nil
	end
	if sound then
		sound:Stop()
	end
end

-- Local mute (the ♪ toggle). The song keeps running silently so it stays on
-- the shared timeline and un-muting is instant.
function MusicController.setMuted(on: boolean)
	muted = on
	local s = sound
	if s then
		s.Volume = if on then 0 else Config.Music.Volume
	end
end

function MusicController.isActive(): boolean
	return startTime ~= nil
end

function MusicController.songTime(): number?
	return songTimeNow()
end

-- Continuous beat for visuals (calibrated by the audio offset); nil = no music.
function MusicController.currentBeat(): number?
	local songTime = songTimeNow()
	if songTime == nil then
		return nil
	end
	return MusicTimeline.beatAt(songTime - MusicTimeline.audioOffset())
end

return MusicController
