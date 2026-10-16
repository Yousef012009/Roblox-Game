--!strict
--[[
	LocalAnim  (ModuleScript)  ·  StarterPlayerScripts/Client/LocalAnim

	Plays one of Config.Animations (Roblox's default emotes) on the LOCAL
	player's own character through Humanoid.Animator. Animations the client
	plays on its own character replicate, so nobody else needs to do
	anything. Bot rigs (server-made, no Player) are never touched here.

	Nil-safe throughout: no character / humanoid / Animator, an empty id or a
	failed load simply means nothing plays. One track at a time.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)

export type Key = "Sit" | "Cheer" | "Point" | "Wave" | "Laugh"

local LocalAnim = {}

local DEFAULT_SECONDS = 3

local animations: { [string]: Animation } = {}
local currentTrack: AnimationTrack? = nil
local serial = 0

local function animatorOf(): Animator?
	local character = Players.LocalPlayer.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return nil
	end
	return humanoid:FindFirstChildOfClass("Animator")
end

local function animationFor(id: string): Animation
	local existing = animations[id]
	if existing then
		return existing
	end
	local animation = Instance.new("Animation")
	animation.Name = "C64Emote"
	animation.AnimationId = id
	animations[id] = animation
	return animation
end

function LocalAnim.stop()
	serial += 1
	local track = currentTrack
	currentTrack = nil
	if track then
		track:Stop(0.25)
		track:Destroy()
	end
end

-- Plays `key` once (or for at most `seconds`). Returns true if it started.
function LocalAnim.play(key: Key, seconds: number?): boolean
	local ids = Config.Animations :: { [string]: string }
	local id = ids[key]
	if type(id) ~= "string" or id == "" then
		return false
	end
	local animator = animatorOf()
	if not animator then
		return false
	end
	LocalAnim.stop()
	local ok, result = pcall(function()
		return animator:LoadAnimation(animationFor(id))
	end)
	if not ok or not result then
		return false
	end
	local track = result :: AnimationTrack
	track.Priority = Enum.AnimationPriority.Action
	track.Looped = false
	track:Play(0.2)
	currentTrack = track
	local mySerial = serial
	local length = if track.Length > 0 then track.Length else DEFAULT_SECONDS
	task.delay(math.min(seconds or length, length + 0.5), function()
		if serial == mySerial then
			LocalAnim.stop()
		end
	end)
	return true
end

return LocalAnim
