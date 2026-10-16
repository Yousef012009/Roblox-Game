--!strict
--[[
	LobbyMusic  (ModuleScript)  ·  StarterPlayerScripts/Client/LobbyMusic

	Background music for the lobby and the elevators: Config.Music.LobbySoundId
	looped at LobbyVolume. ClientManager calls setLobby(false) when the local
	player's match starts (fade out over LobbyFadeSeconds, then pause) and
	setLobby(true) after CLEANUP (resume + fade back in).

	Also owns the small ♪ mute toggle (left edge, mid-height: clear of the
	thumbstick, jump button, HUD and party menu). Mute is local and silences
	both the lobby music and the match song (MusicController.setMuted).

	Graceful: an empty id creates no Sound at all; an id that never loads just
	stays silent (Roblox starts it once loaded).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")

local Config = require(ReplicatedStorage.Shared.Config)
local MusicController = require(script.Parent.MusicController)
local UIKit = require(script.Parent.UIKit)

local LobbyMusic = {}

local sound: Sound? = nil
local inLobby = false
local muted = false
local fade: Tween? = nil
local generation = 0
local muteButton: TextButton? = nil

local function getSound(): Sound?
	local id = Config.Music.LobbySoundId
	if type(id) ~= "string" or id == "" then
		return nil
	end
	if not sound then
		local s = Instance.new("Sound")
		s.Name = "Concentration64LobbyMusic"
		s.SoundId = id
		s.Looped = true
		s.Volume = 0
		s.Parent = SoundService
		sound = s
	end
	return sound
end

local function targetVolume(): number
	return if muted or not inLobby then 0 else Config.Music.LobbyVolume
end

local function apply(seconds: number)
	local s = getSound()
	if not s then
		return
	end
	generation += 1
	local myGeneration = generation
	if fade then
		fade:Cancel()
		fade = nil
	end
	local goal = targetVolume()
	if inLobby and not s.IsPlaying then
		if s.TimePosition > 0 then
			s:Resume()
		else
			s:Play()
		end
	end
	if seconds <= 0 then
		s.Volume = goal
	else
		fade = UIKit.tween(
			s,
			TweenInfo.new(seconds, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut),
			{ Volume = goal }
		)
	end
	if not inLobby then
		-- Pause once silent so a match costs nothing; resume later from here.
		task.delay(math.max(seconds, 0) + 0.05, function()
			if generation == myGeneration and not inLobby and s.IsPlaying then
				s:Pause()
			end
		end)
	end
end

local function refreshButton()
	local button = muteButton
	if not button then
		return
	end
	UIKit.setText(button, if muted then "♪×" else "♪")
	button.TextColor3 = if muted then UIKit.Colors.Red else UIKit.Colors.Phosphor
	local stroke = button:FindFirstChildOfClass("UIStroke")
	if stroke then
		stroke.Color = if muted then UIKit.Colors.Red else UIKit.Colors.Phosphor
	end
end

function LobbyMusic.mount(parent: Instance)
	local button = UIKit.button({
		Name = "MuteToggle",
		Text = "♪",
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 6, 0.5, 0),
		Size = UDim2.fromOffset(UIKit.TouchMin, UIKit.TouchMin),
		BackgroundTransparency = 0.35,
		ZIndex = 45,
		Parent = parent,
	}, UIKit.Colors.Phosphor, 22)
	muteButton = button
	button.Activated:Connect(function()
		LobbyMusic.setMuted(not muted)
		UIKit.pulse(button, 1.2)
	end)
	refreshButton()
end

-- true = lobby / elevator (music on); false = in a match (faded out).
function LobbyMusic.setLobby(on: boolean)
	if on == inLobby then
		return
	end
	inLobby = on
	apply(Config.Music.LobbyFadeSeconds)
end

function LobbyMusic.setMuted(on: boolean)
	if on == muted then
		return
	end
	muted = on
	MusicController.setMuted(on)
	refreshButton()
	apply(0.25)
end

function LobbyMusic.isMuted(): boolean
	return muted
end

function LobbyMusic.isLobby(): boolean
	return inLobby
end

return LobbyMusic
