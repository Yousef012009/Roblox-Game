--!strict
--[[
	Remotes  (ModuleScript)  ·  ReplicatedStorage/Shared/Remotes

	The network contract between server and client.

	  • On the SERVER, requiring this module creates ReplicatedStorage.Remotes
	    and every RemoteEvent / RemoteFunction inside it, or reuses any you
	    already made by hand.
	  • On the CLIENT, it waits for those instances.

	So there is nothing to set up by hand in ReplicatedStorage beyond the
	`Shared` folder that holds this module. The exported types below describe
	every payload, which gives you autocomplete on both sides.

	SECURITY: everything arriving Client → Server is untrusted. GameManager
	type-checks, rate-limits and re-validates every argument. The client UI
	only ever *requests*; the server decides.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local IS_SERVER = RunService:IsServer()

----------------------------------------------------------------------------
-- Payload types (shared by GameManager and ClientManager)
----------------------------------------------------------------------------
export type Phase = "Lobby" | "Intermission" | "Seating" | "Chant" | "CategoryPick" | "Turns" | "RoundOver"

export type RosterStatus = "Active" | "Pending" | "Eliminated" | "Left"

export type RosterEntry = {
	userId: number,
	name: string,
	seat: number,
	status: RosterStatus,
}

export type RhythmSync = {
	bpm: number,
	startTime: number, -- workspace:GetServerTimeNow() timestamp of beat 0
	beatsPerBar: number,
}

export type TurnInfo = {
	id: number,
	userId: number,
	name: string,
	startsAt: number, -- server-clock time the turn opens (always on a beat)
	endsAt: number, -- server-clock deadline ("no hesitation!")
	turnNumber: number,
}

export type AnswerResultKind = "Accepted" | "Skipped" | "Timeout" | "Repeat" | "Revived" | "Eliminated"

export type AnswerResult = {
	userId: number,
	name: string,
	result: AnswerResultKind,
	word: string?, -- Accepted: the (filtered) word. Repeat: the earlier word it matched
	saidBy: string?, -- Repeat: who said it first
	reason: string?, -- Eliminated: "Timeout" | "Repeat" | "Left"
	bribeEndsAt: number?, -- Timeout/Repeat: set when the bribe window is open
}

export type CategoryOption = { index: number, name: string }

export type CategoryPrompt = {
	options: { CategoryOption },
	endsAt: number,
	canCustom: boolean, -- player owns the Custom Category pass
	customEnabled: boolean, -- the pass is configured (show the "unlock" upsell)
}

export type CategoryChosen = {
	category: string,
	callerName: string,
	custom: boolean,
}

export type BribeOffer = {
	endsAt: number,
	reason: string, -- "Timeout" | "Repeat"
}

export type Wallet = {
	Tokens: { SkipTurn: number, Revive: number, ForceCaller: number },
	Enabled: { SkipTurn: boolean, Revive: boolean, ForceCaller: boolean, CustomCategory: boolean },
	HasCustomCategory: boolean,
	ForceCallerArmed: boolean,
}

export type Snapshot = {
	phase: Phase,
	phaseData: { [string]: any },
	sync: RhythmSync?,
	roster: { RosterEntry },
	category: string?,
	turn: TurnInfo?,
	wallet: Wallet?,
}

----------------------------------------------------------------------------
-- Instance creation / lookup
----------------------------------------------------------------------------
local function getFolder(): Instance
	if IS_SERVER then
		local folder = ReplicatedStorage:FindFirstChild("Remotes")
		if not folder then
			folder = Instance.new("Folder")
			folder.Name = "Remotes"
			folder.Parent = ReplicatedStorage
		end
		return folder :: Instance
	end
	return ReplicatedStorage:WaitForChild("Remotes")
end

local folder = getFolder()

local function get(name: string, className: string): any
	if IS_SERVER then
		local existing = folder:FindFirstChild(name)
		if existing then
			assert(existing:IsA(className), `Remotes.{name} must be a {className}`)
			return existing
		end
		local remote = Instance.new(className :: any)
		remote.Name = name
		remote.Parent = folder
		return remote
	end
	return folder:WaitForChild(name)
end

local Remotes = {
	------------------------------------------------------------------ S → C
	-- (phase: Phase, data: {[string]: any})  phase machine heartbeat
	PhaseChanged = get("PhaseChanged", "RemoteEvent") :: RemoteEvent,
	-- (sync: RhythmSync?)  start/retime/stop the shared metronome
	RhythmSync = get("RhythmSync", "RemoteEvent") :: RemoteEvent,
	-- (roster: {RosterEntry})  who is seated and their status
	RosterChanged = get("RosterChanged", "RemoteEvent") :: RemoteEvent,
	-- (turn: TurnInfo)
	TurnStarted = get("TurnStarted", "RemoteEvent") :: RemoteEvent,
	-- (result: AnswerResult)
	AnswerResult = get("AnswerResult", "RemoteEvent") :: RemoteEvent,
	-- (reason: string)  only to the typist: "try again, timer still running"
	AnswerRejected = get("AnswerRejected", "RemoteEvent") :: RemoteEvent,
	-- (prompt: CategoryPrompt?)  only to the Caller; nil closes the picker
	CategoryPrompt = get("CategoryPrompt", "RemoteEvent") :: RemoteEvent,
	-- (info: CategoryChosen)
	CategoryChosen = get("CategoryChosen", "RemoteEvent") :: RemoteEvent,
	-- (offer: BribeOffer?)  only to the player who failed; nil closes it
	BribeOffer = get("BribeOffer", "RemoteEvent") :: RemoteEvent,
	-- (wallet: Wallet)  only to its owner
	WalletChanged = get("WalletChanged", "RemoteEvent") :: RemoteEvent,
	-- (message: string, kind: "Info" | "Success" | "Error"?)
	Notify = get("Notify", "RemoteEvent") :: RemoteEvent,

	------------------------------------------------------------------ C → S
	-- (seq: number, draft: string)  live typing. Unreliable, because only
	-- the newest draft matters and a dropped one is harmless.
	TypingUpdate = get("TypingUpdate", "UnreliableRemoteEvent") :: UnreliableRemoteEvent,
	-- (answer: string)
	SubmitAnswer = get("SubmitAnswer", "RemoteEvent") :: RemoteEvent,
	-- (kind: "Preset" | "Custom", value: number | string)
	SubmitCategory = get("SubmitCategory", "RemoteEvent") :: RemoteEvent,
	-- (key: "SkipTurn" | "Revive" | "ForceCaller" | "CustomCategory")
	-- "Purchase validation": the server checks the request is legal right now,
	-- spends an owned token if there is one, and otherwise opens the Robux
	-- prompt itself.
	RequestPurchase = get("RequestPurchase", "RemoteEvent") :: RemoteEvent,
	-- ()  "Accept fate": closes the bribe window early
	DeclineBribe = get("DeclineBribe", "RemoteEvent") :: RemoteEvent,

	----------------------------------------------------------- functions
	-- () -> Snapshot  full state for (re)joining clients
	GetSnapshot = get("GetSnapshot", "RemoteFunction") :: RemoteFunction,
}

return Remotes
