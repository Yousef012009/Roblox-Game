--!strict
--[[
	RhythmController  (ModuleScript)  ·  StarterPlayerScripts/Client/RhythmController

	Turns the server's tiny RhythmSync table into:
	  • a swinging visual METRONOME (pendulum + 4 beat pips) in the HUD
	  • tick / accent sounds on every beat
	  • the beat-by-beat chant in the centre banner:
	        1 · 2 · 3 · 4
	        CON · CEN · TRA · TION!
	        SIX · TY · FOUR! · 👏
	        NO · RE · PEATS · 👏
	        OR · HESI · TA · TION!
	        I'LL GO FIRST, · TO MY LEFT, · THE CATEGORY · IS...
	  • an optional backing loop whose PlaybackSpeed follows the BPM

	Each frame it reads workspace:GetServerTimeNow(), so every phone and PC
	sees the same beat no matter its ping. Nothing is streamed.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Rhythm = require(Shared:WaitForChild("Rhythm"))
local UIKit = require(script.Parent.UIKit)
local HUDController = require(script.Parent.HUDController)

local C = UIKit.Colors
local SWING_DEGREES = 28

export type ChantInfo = {
	countIn: number,
	callerName: string,
	sync: Rhythm.Sync?,
}

type BeatListener = (beat: number, accent: boolean) -> ()

local RhythmController = {}
RhythmController.__index = RhythmController

export type RhythmController = typeof(setmetatable(
	{} :: {
		_hud: HUDController.HUD,
		_pivot: Frame,
		_pips: { Frame },
		_sync: Rhythm.Sync?,
		_nextSync: Rhythm.Sync?,
		_parity: number,
		_lastBeat: number?,
		_chant: ChantInfo?,
		_intensity: number,
		_listeners: { BeatListener },
		_tick: Sound?,
		_accent: Sound?,
		_music: Sound?,
	},
	RhythmController
))

local function makeSound(name: string, soundId: string, volume: number, looped: boolean?): Sound?
	if soundId == "" then
		return nil
	end
	local sound = Instance.new("Sound")
	sound.Name = "C64_" .. name
	sound.SoundId = soundId
	sound.Volume = volume
	sound.Looped = looped == true
	sound.Parent = SoundService -- created by a LocalScript, so only this player hears it
	return sound
end

function RhythmController.new(holder: Frame, hud: HUDController.HUD): RhythmController
	local self = setmetatable({}, RhythmController) :: any
	self._hud = hud
	self._parity = 0
	self._intensity = 0
	self._listeners = {}

	-- Beat pips across the top of the metronome.
	local pipRow = UIKit.create("Frame", {
		Name = "Pips",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 5),
		Size = UDim2.new(1, -12, 0, 6),
		BackgroundTransparency = 1,
		Parent = holder,
	}, { UIKit.list(Enum.FillDirection.Horizontal, 4) })
	self._pips = {}
	for i = 1, Config.Rhythm.BeatsPerBar do
		self._pips[i] = UIKit.create("Frame", {
			Name = `Pip{i}`,
			Size = UDim2.fromOffset(6, 6),
			BackgroundColor3 = C.Line,
			LayoutOrder = i,
			Parent = pipRow,
		}, { UIKit.round() })
	end

	-- Pendulum. GuiObject.Rotation spins around the object's CENTRE, so the
	-- pivot frame is twice the arm's length and only its top half is drawn.
	self._pivot = UIKit.create("Frame", {
		Name = "Pivot",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, 0, 1, -8),
		Size = UDim2.fromOffset(4, 60),
		BackgroundTransparency = 1,
		Parent = holder,
	})
	UIKit.create("Frame", {
		Name = "Arm",
		Size = UDim2.fromScale(1, 0.5),
		BackgroundColor3 = C.Paper,
		BorderSizePixel = 0,
		Parent = self._pivot,
	}, { UIKit.round() })
	UIKit.create("Frame", {
		Name = "Weight",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, 0, 0, 9),
		Size = UDim2.fromOffset(10, 10),
		BackgroundColor3 = C.Amber,
		Parent = self._pivot,
	}, { UIKit.round() })
	UIKit.create("Frame", {
		Name = "Hub",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, 0, 1, -8),
		Size = UDim2.fromOffset(8, 8),
		BackgroundColor3 = C.Muted,
		ZIndex = 2,
		Parent = holder,
	}, { UIKit.round() })

	local audio = Config.Audio
	self._tick = makeSound("Tick", audio.Tick, audio.TickVolume)
	self._accent = makeSound("Accent", audio.Accent, audio.TickVolume * 1.4)
	self._music = makeSound("Music", audio.Music.SoundId, audio.Music.Volume, true)
	return self
end

----------------------------------------------------------------------------
-- Sync
----------------------------------------------------------------------------
-- A new tempo that starts in the future is queued, so the current groove
-- keeps playing until the exact beat the server chose.
function RhythmController.setSync(self: RhythmController, sync: Rhythm.Sync?, serverNow: number)
	if sync == nil then
		self._sync = nil
		self._nextSync = nil
		self._lastBeat = nil
		self._chant = nil
		local music = self._music
		if music then
			music:Stop()
		end
		return
	end

	if self._sync and sync.startTime > serverNow then
		self._nextSync = sync
	else
		self._sync = sync
		self._nextSync = nil
		self._parity = 0
		self._lastBeat = nil
	end

	local music = self._music
	if music then
		music.PlaybackSpeed = sync.bpm / Config.Audio.Music.BaseBpm
		if not music.IsPlaying then
			music:Play()
		end
	end
end

function RhythmController.getSync(self: RhythmController): Rhythm.Sync?
	return self._nextSync or self._sync
end

-- 0 = silent, 1 = full. Lower while the Caller is choosing.
function RhythmController.setIntensity(self: RhythmController, intensity: number)
	self._intensity = intensity
end

function RhythmController.onBeat(self: RhythmController, listener: BeatListener)
	table.insert(self._listeners, listener)
end

----------------------------------------------------------------------------
-- Chant
----------------------------------------------------------------------------
function RhythmController.startChant(self: RhythmController, countIn: number, callerName: string)
	self._chant = { countIn = countIn, callerName = callerName, sync = self:getSync() }
end

function RhythmController.stopChant(self: RhythmController)
	if self._chant then
		self._chant = nil
		self._hud:setChant(nil)
	end
end

local function renderBar(syllables: { string }, index: number): string
	local parts = table.create(#syllables)
	for i, syllable in syllables do
		local text = if syllable == Rhythm.ClapSyllable then "👏" else syllable
		if i == index then
			parts[i] = `<font color="{UIKit.hex(C.Amber)}">{text}</font>`
		elseif i < index then
			parts[i] = text
		else
			parts[i] = `<font transparency="0.65">{text}</font>`
		end
	end
	return table.concat(parts, "  ")
end

function RhythmController._renderChant(self: RhythmController, beat: number): boolean
	local chant = self._chant
	if not chant then
		return false
	end
	local frame = Rhythm.chantFrame(beat, chant.countIn)
	local syllables = frame.syllables
	if frame.kind == "CountIn" then
		self._hud:setChant(tostring(frame.count), "CONCENTRATION 64 · GET READY", true)
	elseif frame.kind == "Chant" and syllables then
		self._hud:setChant(renderBar(syllables, frame.index or 1), "NO REPEATS · NO HESITATION", true)
		return syllables[frame.index or 1] == Rhythm.ClapSyllable
	elseif frame.kind == "Caller" and syllables then
		self._hud:setChant(renderBar(syllables, frame.index or 1), `🕵 {string.upper(chant.callerName)} IS THE CALLER`, true)
	elseif frame.kind == "Done" then
		self:stopChant()
	end
	return false
end

----------------------------------------------------------------------------
-- Per-frame
----------------------------------------------------------------------------
function RhythmController._onBeat(self: RhythmController, beat: number, sync: Rhythm.Sync)
	local inBar = Rhythm.beatInBar(sync, beat)
	for i, pip in self._pips do
		pip.BackgroundColor3 = if i - 1 == inBar then (if inBar == 0 then C.Amber else C.Paper) else C.Line
	end

	local accent = inBar == 0
	local chant = self._chant
	if chant and chant.sync == sync and self:_renderChant(beat) then
		accent = true -- the claps in the chant
	end

	if self._intensity > 0 then
		local sound = if accent then self._accent else self._tick
		if sound then
			sound.Volume = Config.Audio.TickVolume * self._intensity * (if accent then 1.4 else 1)
			SoundService:PlayLocalSound(sound)
		end
	end

	for _, listener in self._listeners do
		task.spawn(listener, beat, accent)
	end
end

function RhythmController.update(self: RhythmController, serverNow: number)
	-- Hand over to a queued tempo exactly on its first beat, keeping the
	-- pendulum swinging the same way.
	local queued = self._nextSync
	if queued and serverNow >= queued.startTime then
		local old = self._sync
		self._parity = if old then (Rhythm.beatIndex(old, serverNow) + self._parity) % 2 else 0
		self._sync = queued
		self._nextSync = nil
		self._lastBeat = nil
	end

	local sync = self._sync
	if not sync then
		self._pivot.Rotation *= 0.9 -- settle to centre
		return
	end

	local beatFloat = Rhythm.beatFloat(sync, serverNow)
	if beatFloat < 0 then
		self._pivot.Rotation = SWING_DEGREES -- cocked, waiting for beat 0
		return
	end

	-- cos(π·beat) puts the pendulum at an extreme exactly on each beat.
	self._pivot.Rotation = SWING_DEGREES * math.cos(math.pi * (beatFloat + self._parity))

	local beat = math.floor(beatFloat)
	if beat ~= self._lastBeat then
		self._lastBeat = beat
		self:_onBeat(beat, sync)
	end
end

return RhythmController
