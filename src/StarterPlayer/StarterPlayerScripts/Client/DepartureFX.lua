--!strict
--[[
	DepartureFX  (ModuleScript)  ·  StarterPlayerScripts/Client/DepartureFX

	The elevator "descends" for the local player once their queue is
	Departing (Config.Queue.DepartSeconds):
	  • camera rumble through the local Humanoid.CameraOffset (works with the
	    default camera, no fighting the camera scripts), ramping up
	  • the chamber's lights flicker (its PointLights / neon status lamps,
	    changed on this client only and restored afterwards)
	  • a floor indicator over the screen: "B1 ▼  B2 ▼  INTERROGATION"
	  • fade to black just before the server moves everyone into the room
	The black stays until ClientManager fades in on INTRO (ScreenFader also
	fades in by itself if INTRO never comes).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage.Shared.Config)
local Names = require(ReplicatedStorage.Shared.Names)
local ScreenFader = require(script.Parent.ScreenFader)

local DepartureFX = {}

local FLOORS = { "B1 ▼", "B1 ▼  B2 ▼", "B1 ▼  B2 ▼  INTERROGATION" }
local FADE_SECONDS = 0.5
local SHAKE_MAX = 0.32 -- studs of CameraOffset jitter at full rumble
local LINGER = 1.5 -- keep rumbling a moment past DepartSeconds if the teleport is late

type LightRecord = { light: Light, enabled: boolean, brightness: number }
type LampRecord = { part: BasePart, material: Enum.Material }

local running = false
local generation = 0
local connection: RBXScriptConnection? = nil
local startedAt = 0
local lights: { LightRecord } = {}
local lamps: { LampRecord } = {}
local humanoid: Humanoid? = nil
local offsetBefore = Vector3.zero
local random = Random.new()
local nextFlicker = 0
local floorShown = 0

local function queueModel(index: number): Instance?
	local map = Workspace:FindFirstChild(Names.Map)
	local queues = map and map:FindFirstChild(Names.Queues)
	return queues and queues:FindFirstChild(Names.Queue(index))
end

local function collect(index: number)
	table.clear(lights)
	table.clear(lamps)
	local model = queueModel(index)
	if not model then
		return
	end
	for _, d in model:GetDescendants() do
		if d:IsA("Light") then
			table.insert(lights, { light = d, enabled = d.Enabled, brightness = d.Brightness })
		elseif d:IsA("BasePart") and d.Material == Enum.Material.Neon then
			table.insert(lamps, { part = d, material = d.Material })
		end
	end
end

local function setFlicker(off: boolean)
	for _, rec in lights do
		if rec.light.Parent then
			rec.light.Enabled = rec.enabled and not off
		end
	end
	for _, rec in lamps do
		if rec.part.Parent then
			rec.part.Material = if off then Enum.Material.SmoothPlastic else rec.material
		end
	end
end

local function restore()
	for _, rec in lights do
		if rec.light.Parent then
			rec.light.Enabled = rec.enabled
			rec.light.Brightness = rec.brightness
		end
	end
	for _, rec in lamps do
		if rec.part.Parent then
			rec.part.Material = rec.material
		end
	end
	table.clear(lights)
	table.clear(lamps)
	local h = humanoid
	if h and h.Parent then
		h.CameraOffset = offsetBefore
	end
	humanoid = nil
end

local function step()
	local now = os.clock()
	local elapsed = now - startedAt
	local depart = Config.Queue.DepartSeconds
	if elapsed > depart + LINGER then
		DepartureFX.stop(false)
		return
	end
	-- Rumble: ramps up over the ride, eases off once the screen is black.
	local ramp = math.clamp(elapsed / math.max(depart, 0.1), 0, 1)
	local amp = SHAKE_MAX * (0.35 + 0.65 * ramp)
	local h = humanoid
	if h and h.Parent then
		h.CameraOffset = offsetBefore
			+ Vector3.new(
				math.noise(now * 9, 0.3) * amp,
				math.noise(0.7, now * 11) * amp,
				math.noise(now * 7, 1.9) * amp * 0.5
			)
	end
	-- Light flicker: short random blackouts.
	if now >= nextFlicker then
		local off = random:NextNumber() < 0.45
		setFlicker(off)
		nextFlicker = now + (if off then random:NextNumber(0.04, 0.12) else random:NextNumber(0.08, 0.3))
	end
	-- Floor indicator, one stop at a time across the ride.
	local floor = math.clamp(math.floor(elapsed / math.max(depart, 0.1) * #FLOORS) + 1, 1, #FLOORS)
	if floor ~= floorShown then
		floorShown = floor
		ScreenFader.setCaption(FLOORS[floor])
	end
end

-- Starts the departure sequence for queue `index` (idempotent while running).
function DepartureFX.start(index: number)
	if running then
		return
	end
	running = true
	generation += 1
	local myGeneration = generation
	startedAt = os.clock()
	nextFlicker = 0
	floorShown = 0
	collect(index)
	local character = Players.LocalPlayer.Character
	local h = character and character:FindFirstChildOfClass("Humanoid")
	humanoid = h
	offsetBefore = if h then h.CameraOffset else Vector3.zero
	connection = RunService.RenderStepped:Connect(step)
	local fadeAt = math.max(0, Config.Queue.DepartSeconds - FADE_SECONDS)
	task.delay(fadeAt, function()
		if generation == myGeneration and running then
			ScreenFader.fadeOut(FADE_SECONDS)
		end
	end)
end

-- Ends the rumble/flicker. `clearScreen` also lifts the black (aborted ride).
function DepartureFX.stop(clearScreen: boolean)
	if not running then
		if clearScreen then
			ScreenFader.fadeIn(0.4)
		end
		return
	end
	running = false
	generation += 1
	if connection then
		connection:Disconnect()
		connection = nil
	end
	restore()
	if clearScreen then
		ScreenFader.fadeIn(0.4)
	end
end

function DepartureFX.isRunning(): boolean
	return running
end

return DepartureFX
