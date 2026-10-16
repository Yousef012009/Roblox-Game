--!strict
--[[
	Rhythm  (ModuleScript)  ·  ReplicatedStorage/Shared/Rhythm

	Pure beat math plus the chant lyrics. The server and every client share
	these functions, so they all agree on when each beat falls.

	HOW SYNC WORKS
	The server never streams beats. It sends one small table:

	    { bpm = 104, startTime = <workspace:GetServerTimeNow()>, beatsPerBar = 4 }

	Every client reads `workspace:GetServerTimeNow()`, which Roblox keeps in
	sync across the network, and works out the current beat locally. Visuals,
	ticks and turn timers therefore line up on every device whatever its ping,
	and the only network traffic is the one table above.
]]

local Rhythm = {}

export type Sync = {
	bpm: number,
	startTime: number,
	beatsPerBar: number,
}

function Rhythm.new(bpm: number, startTime: number, beatsPerBar: number?): Sync
	return { bpm = bpm, startTime = startTime, beatsPerBar = beatsPerBar or 4 }
end

-- Seconds per beat.
function Rhythm.interval(sync: Sync): number
	return 60 / sync.bpm
end

-- Continuous beat position at server-time `t` (negative before beat 0).
function Rhythm.beatFloat(sync: Sync, t: number): number
	return (t - sync.startTime) / Rhythm.interval(sync)
end

-- Whole beat index at server-time `t`.
function Rhythm.beatIndex(sync: Sync, t: number): number
	return math.floor(Rhythm.beatFloat(sync, t))
end

-- Server-time of beat `i`.
function Rhythm.timeOfBeat(sync: Sync, i: number): number
	return sync.startTime + i * Rhythm.interval(sync)
end

-- First beat strictly after `t`, never earlier than beat 0.
function Rhythm.nextBeatTime(sync: Sync, t: number): number
	return math.max(Rhythm.timeOfBeat(sync, Rhythm.beatIndex(sync, t) + 1), sync.startTime)
end

-- 0-based position of beat `i` inside its bar (0 = downbeat).
function Rhythm.beatInBar(sync: Sync, i: number): number
	return i % sync.beatsPerBar
end

----------------------------------------------------------------------------
-- The chant: one syllable per beat, four beats per bar.
----------------------------------------------------------------------------
Rhythm.ChantBars = table.freeze({
	table.freeze({ "CON", "CEN", "TRA", "TION!" }),
	table.freeze({ "SIX", "TY", "FOUR!", "*CLAP*" }),
	table.freeze({ "NO", "RE", "PEATS", "*CLAP*" }),
	table.freeze({ "OR", "HESI", "TA", "TION!" }),
})

-- The Caller's line, sung on the bar after the chant.
Rhythm.CallerBar = table.freeze({ "I'LL GO FIRST,", "TO MY LEFT,", "THE CATEGORY", "IS..." })

Rhythm.ClapSyllable = "*CLAP*"

-- Total beats in the chant sequence (count-in + chant + caller line).
function Rhythm.chantLength(countIn: number): number
	return countIn + #Rhythm.ChantBars * 4 + #Rhythm.CallerBar
end

export type ChantFrame = {
	kind: "Waiting" | "CountIn" | "Chant" | "Caller" | "Done",
	count: number?, -- CountIn: 1..countIn
	syllables: { string }?, -- Chant/Caller: the whole bar
	index: number?, -- which syllable lands on this beat (1-based)
}

-- What should be on screen at beat `beat`, counted from the chant's sync.startTime.
function Rhythm.chantFrame(beat: number, countIn: number): ChantFrame
	if beat < 0 then
		return { kind = "Waiting" }
	end
	if beat < countIn then
		return { kind = "CountIn", count = beat + 1 }
	end

	local b = beat - countIn
	local chantBeats = #Rhythm.ChantBars * 4
	if b < chantBeats then
		return { kind = "Chant", syllables = Rhythm.ChantBars[b // 4 + 1], index = b % 4 + 1 }
	end

	b -= chantBeats
	if b < #Rhythm.CallerBar then
		return { kind = "Caller", syllables = Rhythm.CallerBar, index = b + 1 }
	end
	return { kind = "Done" }
end

return Rhythm
