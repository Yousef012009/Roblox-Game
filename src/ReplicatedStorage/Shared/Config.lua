--!strict
--[[
	Config  (ModuleScript)  ·  ReplicatedStorage/Shared/Config

	THE single place for every gameplay constant. Server, client and the map
	generator all read this module. Nothing here is secret.

	Most-edited values:
	  • Music.SoundId            upload your track, paste "rbxassetid://<id>"
	  • Queue.MinPlayersToStart  4 for real play; Studio tests use StudioMinPlayersToStart
	  • Match.RoundsPerMatch     0 = one round per player (everyone is Caller once)
	  • Turn.BeatsPerTurn        answer window, in beats of the song
]]

local Config = {}

----------------------------------------------------------------------------
-- Queues (the four elevator chambers in the lobby)
----------------------------------------------------------------------------
Config.Queue = {
	Count = 4, -- Queue01..Queue04 (the map generator builds this many)
	Capacity = 4, -- players per chamber / per match
	MinPlayersToStart = 4, -- live servers: start only when the chamber is full
	StudioMinPlayersToStart = 3, -- Studio: 3 is the smallest playable match (1 Caller + 2 answerers)
	PartialStartDelaySeconds = 12, -- below Capacity but at/over the minimum: wait this long for more
	StartCountdownSeconds = 4, -- "doors closing" countdown once a start is possible
	DepartSeconds = 1.5, -- doors shut, elevator "moves", then players arrive in the room
	ScanInterval = 0.2, -- server spatial check rate (seconds)
	ExitMarginStuds = 1.5, -- hysteresis: you must step this far outside the zone to leave
}

----------------------------------------------------------------------------
-- Matches
----------------------------------------------------------------------------
Config.Match = {
	MinPlayersToContinue = 3, -- Caller + 2 answerers; below this the match ends
	RoundsPerMatch = 0, -- 0 = one round per starting player, so everyone is Caller once. 1 = single round.
	MaxConcurrentMatches = 8, -- room slots; queues wait if all are busy
	RoomOrigin = Vector3.new(100, 0, 0), -- slot 0 (the first room) is placed here
	RoomSpacing = 320, -- studs between slots along Z (slot 1 at +Z, slot 2 at -Z, ...)

	IntroSeconds = 4.5, -- elevator → room cinematic
	CallerRevealSeconds = 3.5,
	CategoryTimeoutSeconds = 45, -- the Caller types a custom category
	EliminationSeconds = 2.6, -- red pulse + teleport beat before play continues
	RoundEndSeconds = 6,
	GameEndSeconds = 9,
	CharacterWaitSeconds = 12, -- how long we wait for a late-loading character
	FallbackCategories = { -- used only if the Caller never submits (timeout) or leaves
		"Things found in a detective's office",
		"Types of cars",
		"Animals with four legs",
		"Famous movie villains",
		"Things that are cold",
		"Breakfast foods",
	},
}

----------------------------------------------------------------------------
-- Turns ("no hesitation")
----------------------------------------------------------------------------
Config.Turn = {
	BeatsPerTurn = 8, -- 8 beats at 90 BPM = 5.33 s
	MinTurnSeconds = 4.0, -- never shorter than this, whatever the BPM
	GapBeats = 1, -- beats between one turn ending and the next beginning
	LatencyGraceSeconds = 0.3, -- an answer that ARRIVES this late is still on time
}

----------------------------------------------------------------------------
-- Caller judging ("VALID" / "GIBBERISH / WRONG")
----------------------------------------------------------------------------
Config.Judging = {
	TimeoutSeconds = 15,
	-- What happens if the Caller never presses a button. An unanswered judging
	-- request is NEVER treated as proof the answer was wrong:
	--   "Accept" → the answer stands (benefit of the doubt). The only allowed value.
	TimeoutPolicy = "Accept",
	MaxConsecutiveTimeouts = 2, -- after this many, the round switches to auto-judging
}

----------------------------------------------------------------------------
-- Text limits (category subject is never restricted, only its length)
----------------------------------------------------------------------------
Config.Text = {
	CategoryMinLength = 2,
	CategoryMaxLength = 48,
	AnswerMinLength = 1,
	AnswerMaxLength = 32,
	RawMaxBytes = 200, -- anything longer from a client is dropped unread
}

----------------------------------------------------------------------------
-- Music. Values measured from the supplied track "Roblox_game_finished.mp3"
-- (24.79 s): 90.00 BPM, 4/4. See docs/MUSIC_ANALYSIS.md.
--
--   0.085 s ─ 10.752 s   CHANT   16 beats (4 bars), one syllable per beat
--  10.752 s ─ 13.130 s   STING   held high note: "THE CATEGORY IS…" reveal
--  13.130 s ─ 23.797 s   LOOP    16 beats (4 bars), looped for gameplay
----------------------------------------------------------------------------
Config.Music = {
	SoundId = "", -- ← paste "rbxassetid://<your uploaded id>". Empty = silent mode (visuals still run on the timeline)
	Volume = 0.6,
	BPM = 90,
	BeatsPerMeasure = 4,
	ChantStart = 0.085, -- song time of beat 0 (first downbeat)
	ChantBeats = 16,
	StingBeats = 4, -- the sting is treated as 4 "virtual" beats so the bulb never stops swinging
	LoopStart = 13.13, -- song time where the gameplay loop begins (beat 20)
	LoopBeats = 16, -- loop length = LoopBeats / BPM * 60 = 10.667 s
	StartLeadInSeconds = 1.0, -- server schedules song start this far in the future so every client starts together
	-- Calibration: positive = visuals happen LATER relative to the audio. Tune
	-- live in Play mode by setting the attribute "AudioOffset" on
	-- ReplicatedStorage.Shared.Config (see docs/MUSIC_ANALYSIS.md).
	AudioOffset = 0,
	ResyncThreshold = 0.09, -- if the Sound drifts more than this from the timeline, snap it
	LoadTimeoutSeconds = 6, -- a missing/unloaded asset never blocks the game
}

----------------------------------------------------------------------------
-- The chant. One entry per beat of the CHANT section (beat = 0..15). `line`
-- groups syllables into the phrase shown on screen. Edit freely to re-time
-- the lyrics; beats with no entry show the previous line unchanged.
----------------------------------------------------------------------------
Config.Chant = {
	{ beat = 0, line = 1, text = "CON" },
	{ beat = 1, line = 1, text = "CEN" },
	{ beat = 2, line = 1, text = "TRA" },
	{ beat = 3, line = 1, text = "TION," },
	{ beat = 4, line = 2, text = "SIX" },
	{ beat = 5, line = 2, text = "TY" },
	{ beat = 6, line = 2, text = "FOUR," },
	{ beat = 8, line = 3, text = "NO" },
	{ beat = 9, line = 3, text = "RE" },
	{ beat = 10, line = 3, text = "PEATS," },
	{ beat = 12, line = 4, text = "OR" },
	{ beat = 13, line = 4, text = "HES" },
	{ beat = 14, line = 4, text = "I" },
	{ beat = 15, line = 4, text = "TATION..." },
}
Config.ChantStingText = "THE CATEGORY IS..."

----------------------------------------------------------------------------
-- Camera
----------------------------------------------------------------------------
Config.Camera = {
	FieldOfView = 60, -- vertical FOV tuned for a 16:9 landscape screen
	MaxFieldOfView = 95, -- portrait phones widen up to this to keep the table in frame
	BlendSeconds = 0.9,
	IntroDollySeconds = 3.5,
	SwayDegrees = 0.35, -- subtle handheld sway; disabled while the local player is typing
}

----------------------------------------------------------------------------
-- Visuals (client-side, cheap)
----------------------------------------------------------------------------
Config.Visual = {
	BulbSwingDegrees = 13, -- pendulum amplitude
	BulbIdleSwingDegrees = 4, -- gentle sway when no music is playing
	BulbBrightness = 2.2,
	BulbBrightnessPulse = 0.35, -- extra brightness on each beat
	EliminationPulseSeconds = 1.2,
	FluorescentFlickerChance = 0.015, -- per light per frame-ish; lobby only
	StaticFps = 12, -- CRT static refresh rate
	StaticMaxDistance = 90, -- CRTs further than this stop animating
}

----------------------------------------------------------------------------
-- Rate limits (per player, per remote)
----------------------------------------------------------------------------
Config.RateLimit = {
	PerSecond = 3,
	Burst = 5,
}

Config.Debug = {
	Verbose = false, -- extra server logs
}

return Config
