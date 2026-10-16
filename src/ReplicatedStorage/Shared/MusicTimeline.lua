--!strict
--[[
	MusicTimeline  (ModuleScript)  ·  ReplicatedStorage/Shared/MusicTimeline

	Pure functions mapping SONG TIME (seconds since the song started playing)
	to MUSICAL BEATS. The server and every client use the same functions, so
	turn deadlines, the metronome, the chant and the swinging bulb all agree.

	A match broadcasts one number: `musicStartTime`, the server clock time
	(Workspace:GetServerTimeNow()) at which song position 0 plays. Then:

	    songTime = Workspace:GetServerTimeNow() - musicStartTime
	    beat     = MusicTimeline.beatAt(songTime)            -- continuous
	    audioPos = MusicTimeline.soundPosition(songTime)     -- where the Sound should be

	No task.wait() chains are involved: every consumer derives the current
	phase from the shared clock each frame, so a client that joins late simply
	lands in the right place.

	Beat numbering (all integers are beats; fractions are phase):
	    beat  0 … 15   CHANT (one syllable per beat)
	    beat 16 … 19   STING (4 "virtual" beats stretched over the held note,
	                   so the pendulum keeps swinging smoothly)
	    beat 20 …      LOOP  (the gameplay groove; repeats every LoopBeats,
	                   and beats keep counting upward forever, unrolled)
]]

local Config = require(script.Parent.Config)

local MusicTimeline = {}

export type Section = "PreRoll" | "Chant" | "Sting" | "Loop"

export type ChantFrame = {
	kind: "Chant" | "Sting" | "None",
	line: number?, -- Chant: which phrase line (Config.Chant[].line)
	syllables: { string }?, -- Chant: every syllable of that line, in order
	active: number?, -- Chant: index into `syllables` of the syllable on this beat
}

local M = Config.Music
local INTERVAL = 60 / M.BPM
local CHANT_END = M.ChantStart + M.ChantBeats * INTERVAL
local LOOP_LENGTH = M.LoopBeats * INTERVAL

assert(M.LoopStart > CHANT_END, "Config.Music.LoopStart must come after the chant ends")
assert(M.StingBeats > 0, "Config.Music.StingBeats must be > 0")

MusicTimeline.Interval = INTERVAL
MusicTimeline.ChantStart = M.ChantStart
MusicTimeline.ChantEnd = CHANT_END
MusicTimeline.LoopStart = M.LoopStart
MusicTimeline.LoopLength = LOOP_LENGTH
MusicTimeline.LoopEnd = M.LoopStart + LOOP_LENGTH
MusicTimeline.StingStartBeat = M.ChantBeats
MusicTimeline.LoopStartBeat = M.ChantBeats + M.StingBeats
MusicTimeline.BeatsPerMeasure = M.BeatsPerMeasure

local STING_DURATION = M.LoopStart - CHANT_END

-- Continuous beat position at `songTime`. Negative before the first downbeat.
function MusicTimeline.beatAt(songTime: number): number
	if songTime < CHANT_END then
		return (songTime - M.ChantStart) / INTERVAL
	elseif songTime < M.LoopStart then
		return M.ChantBeats + M.StingBeats * (songTime - CHANT_END) / STING_DURATION
	end
	return MusicTimeline.LoopStartBeat + (songTime - M.LoopStart) / INTERVAL
end

-- Song time at which (possibly fractional) `beat` happens. Inverse of beatAt.
function MusicTimeline.timeOfBeat(beat: number): number
	if beat < M.ChantBeats then
		return M.ChantStart + beat * INTERVAL
	elseif beat < MusicTimeline.LoopStartBeat then
		return CHANT_END + (beat - M.ChantBeats) / M.StingBeats * STING_DURATION
	end
	return M.LoopStart + (beat - MusicTimeline.LoopStartBeat) * INTERVAL
end

-- Smallest whole beat that happens at or after `songTime`, never before `minBeat`.
function MusicTimeline.nextBeat(songTime: number, minBeat: number?): number
	local beat = math.ceil(MusicTimeline.beatAt(songTime) - 1e-6)
	return math.max(beat, minBeat or -math.huge)
end

-- Where the audio file should be playing at `songTime` (applies the loop).
function MusicTimeline.soundPosition(songTime: number): number
	if songTime < MusicTimeline.LoopEnd then
		return math.max(songTime, 0)
	end
	return M.LoopStart + (songTime - M.LoopStart) % LOOP_LENGTH
end

function MusicTimeline.section(songTime: number): Section
	if songTime < M.ChantStart then
		return "PreRoll"
	elseif songTime < CHANT_END then
		return "Chant"
	elseif songTime < M.LoopStart then
		return "Sting"
	end
	return "Loop"
end

-- Measure number and 0-based beat within the measure for a continuous beat.
function MusicTimeline.measureOf(beat: number): (number, number)
	local whole = math.floor(beat)
	return whole // M.BeatsPerMeasure, whole % M.BeatsPerMeasure
end

-- Number of beats a turn lasts (Config.Turn.BeatsPerTurn, stretched so it is
-- never shorter than Config.Turn.MinTurnSeconds).
function MusicTimeline.beatsPerTurn(): number
	return math.max(Config.Turn.BeatsPerTurn, math.ceil(Config.Turn.MinTurnSeconds / INTERVAL))
end

-- Calibration offset (seconds). Config value, overridable live through the
-- "AudioOffset" attribute on the Config ModuleScript (Studio tuning).
function MusicTimeline.audioOffset(): number
	local configModule = script.Parent:FindFirstChild("Config")
	local override = configModule and configModule:GetAttribute("AudioOffset")
	if type(override) == "number" then
		return override
	end
	return M.AudioOffset
end

----------------------------------------------------------------------------
-- Chant
----------------------------------------------------------------------------
type ChantEntry = { beat: number, line: number, text: string }

local chantByLine: { [number]: { ChantEntry } } = {}
local chantSorted: { ChantEntry } = {}
for _, entry in Config.Chant do
	table.insert(chantSorted, entry)
	local list = chantByLine[entry.line]
	if not list then
		list = {}
		chantByLine[entry.line] = list
	end
	table.insert(list, entry)
end
table.sort(chantSorted, function(a, b)
	return a.beat < b.beat
end)
for _, list in chantByLine do
	table.sort(list, function(a, b)
		return a.beat < b.beat
	end)
end

-- What the chant display should show at continuous `beat`.
function MusicTimeline.chantFrame(beat: number): ChantFrame
	if beat < 0 or beat >= MusicTimeline.LoopStartBeat then
		return { kind = "None" }
	end
	if beat >= M.ChantBeats then
		return { kind = "Sting" }
	end

	local whole = math.floor(beat)
	local current: ChantEntry? = nil
	for _, entry in chantSorted do
		if entry.beat <= whole then
			current = entry
		else
			break
		end
	end
	if not current then
		return { kind = "None" }
	end

	local list = chantByLine[current.line]
	local syllables = table.create(#list)
	local active = 1
	for index, entry in list do
		syllables[index] = entry.text
		if entry == current then
			active = index
		end
	end
	return { kind = "Chant", line = current.line, syllables = syllables, active = active }
end

return MusicTimeline
