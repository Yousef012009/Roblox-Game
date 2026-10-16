--!strict
--[[
	Config  (ModuleScript)  ·  ReplicatedStorage/Shared/Config

	Every tunable number in the game lives here. Both the server and the client
	require this module, so do not put anything secret in it. Product IDs are
	public anyway.

	BEFORE YOU PUBLISH:
	  1. Creator Dashboard → your experience → Monetization:
	       • create the Game Pass "Custom Category"
	       • create the Developer Products "Skip Turn", "Bribe the Detective"
	         (revive) and "Force Caller"
	  2. Paste their IDs into `Config.GamePasses` / `Config.Products` below.
	     An ID of 0 disables that feature in live servers (its button is hidden).
	  3. Studio → Game Settings → Places → Max Players = 6.
	  4. Studio → Game Settings → Security → "Enable Studio Access to API
	     Services" if you want DataStores (saved tokens and wins) while testing.
]]

local Config = {}

----------------------------------------------------------------------------
-- Players
----------------------------------------------------------------------------
Config.Players = {
	MaxActive = 4, -- seats in the Interrogation Room (server max is 6, set in Game Settings)
	MinToStart = 2, -- live servers wait for this many players
	AllowSoloInStudio = true, -- Play Solo in Studio starts a 1-player round so you can test
}

----------------------------------------------------------------------------
-- Phase timings (seconds)
----------------------------------------------------------------------------
Config.Timing = {
	IntermissionSeconds = 15, -- lobby countdown once enough players are present
	SeatingSeconds = 3, -- time to sit everyone down before the chant
	CategoryPickSeconds = 15, -- how long the Caller has to choose
	RoundOverSeconds = 7, -- "CASE CLOSED" screen before returning to the lobby
	LatencyGraceSeconds = 0.35, -- answers that arrive this late are still accepted (network lag)
}

----------------------------------------------------------------------------
-- Rhythm: the clapping beat that drives the chant and every turn
----------------------------------------------------------------------------
Config.Rhythm = {
	BeatsPerBar = 4, -- the chant is written in 4/4, so leave this at 4
	CountInBeats = 4, -- "1, 2, 3, 4" count-off before the chant
	StartBpmChoices = { 88, 96, 104, 112 }, -- each round picks one at random
	BpmIncreasePerLap = 6, -- the beat speeds up each time play goes all the way round the table
	MaxBpm = 140,
}

----------------------------------------------------------------------------
-- Turns: "no hesitation!"
----------------------------------------------------------------------------
Config.Turn = {
	Beats = 10, -- each turn lasts this many beats (shrinks in seconds as the BPM rises)
	MinSeconds = 3.5, -- but never less than this (mobile typing needs time)
	ResultHoldSeconds = 0.9, -- pause after each answer so everyone can read the TV
	MaxTurnsPerRound = 250, -- safety valve
}

----------------------------------------------------------------------------
-- Answer rules: "no repeats!"
----------------------------------------------------------------------------
Config.Words = {
	MinLength = 2,
	MaxLength = 30,
	TreatPluralsAsRepeats = true, -- "cat" then "cats" counts as a repeat
	IgnoreLeadingArticles = true, -- "the moon" then "moon" counts as a repeat
}

Config.Category = {
	ChoicesOffered = 8, -- the Caller sees this many random preset categories
	CustomMinLength = 3,
	CustomMaxLength = 40,
}

----------------------------------------------------------------------------
-- Monetization
----------------------------------------------------------------------------
Config.GamePasses = {
	CustomCategory = 0, -- Game Pass: type any category when you are the Caller
}

Config.Products = {
	SkipTurn = 0, -- Developer Product: skip your turn without being eliminated
	Revive = 0, -- Developer Product: "Bribe the Detective" to stay in after failing
	ForceCaller = 0, -- Developer Product: be the Caller next round
}

Config.Bribe = {
	WindowSeconds = 5, -- how long the "Bribe the Detective?" offer stays open
}

Config.Purchases = {
	-- While a purchase dialog the server opened is still on screen, a pending
	-- deadline (turn timeout or bribe window) is held, up to this long. This
	-- stops a slow dialog from costing the player Robux AND their seat.
	PromptHoldMaxSeconds = 15,
	-- After the dialog closes with "purchased", wait this long for
	-- ProcessReceipt to arrive before the deadline is enforced.
	ReceiptWaitSeconds = 6,
}

----------------------------------------------------------------------------
-- Live typing broadcast to the TV
----------------------------------------------------------------------------
Config.Typing = {
	ClientSendInterval = 0.12, -- the client sends its draft at most this often
	ServerMinInterval = 0.2, -- the server filters and broadcasts drafts at most this often per player
}

----------------------------------------------------------------------------
-- Audio (client). Built-in rbxasset sounds work out of the box. Replace them
-- with your own uploads ("rbxassetid://123") for a custom feel. An empty
-- string disables that sound.
----------------------------------------------------------------------------
Config.Audio = {
	Tick = "rbxasset://sounds/clickfast.wav", -- every beat
	Accent = "rbxasset://sounds/electronicpingshort.wav", -- first beat of the bar and the chant claps
	YourTurn = "rbxasset://sounds/electronicpingshort.wav",
	Accepted = "rbxasset://sounds/button.wav",
	Eliminated = "rbxasset://sounds/swoosh.wav",
	TickVolume = 0.35,
	-- Optional backing loop. Record it at BaseBpm; the client changes its
	-- PlaybackSpeed to match each round's tempo.
	Music = {
		SoundId = "",
		BaseBpm = 100,
		Volume = 0.35,
	},
}

----------------------------------------------------------------------------
-- Map & data
----------------------------------------------------------------------------
Config.Map = {
	-- If Workspace has no "InterrogationRoom" model, the server builds a
	-- graybox room, lounge and lobby so you can press Play right away. Build
	-- your own map (see docs/STUDIO_SETUP.md) and this does nothing.
	AutoBuildGraybox = true,
}

Config.Data = {
	StoreName = "Concentration64_PlayerData_v1",
	AutoSaveSeconds = 45, -- pending token/win changes are flushed this often
	MaxStoredReceipts = 50, -- recent PurchaseIds kept per player for de-duplication
}

Config.Debug = {
	-- In Studio only: products and passes whose ID is still 0 are "bought"
	-- instantly for free so you can test every purchase flow before you
	-- create the real products. Has no effect in live servers.
	SimulateMissingProductsInStudio = true,
	Verbose = false, -- extra server logs
}

return Config
