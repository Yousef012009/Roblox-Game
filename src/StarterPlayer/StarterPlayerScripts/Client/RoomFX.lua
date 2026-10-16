--!strict
--[[
	RoomFX  (ModuleScript)  ·  StarterPlayerScripts/Client/RoomFX

	Client-local effects for the local player's OWN match room only:
	  • swinging bulb (pendulum on the beat, idle sway without music, blended)
	  • bulb brightness pulse on every beat
	  • elimination: bulb + RoomLights tint red, AlarmStrip lights up
	  • two-way mirror: opaque/reflective for seated players, dim glass for spectators
	  • CRT static on the TV (when it shows no category/answer) and room CRTs

	Nothing here replicates: all changes are made on the client's copy.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Config = require(ReplicatedStorage.Shared.Config)
local Names = require(ReplicatedStorage.Shared.Names)
local MusicController = require(script.Parent.MusicController)
local StaticNoise = require(script.Parent.StaticNoise)

-- Not (yet) part of Names.lua; see the client report's contract requests.
local ALARM_STRIP_NAME = "AlarmStrip"

local RED = Color3.fromRGB(255, 40, 30)
local WAIT_TIMEOUT = 10
local BLEND_SECONDS = 0.8 -- music ↔ idle swing crossfade
local IDLE_PERIOD = 3.4 -- seconds per idle sway cycle

type LightRecord = { light: Light, color: Color3, brightness: number }
type PartRecord = { part: BasePart, color: Color3, material: Enum.Material }
type MirrorRecord = {
	part: BasePart,
	transparency: number,
	reflectance: number,
	color: Color3,
	material: Enum.Material,
}

local RoomFX = {}

local room: Model? = nil
local token = 0 -- invalidates async setup threads of a previous room
local connections: { RBXScriptConnection } = {}
local spectatorMode = false

local pivot: BasePart? = nil
local assembly: Model? = nil
local assemblyOffset: CFrame? = nil
local bulbLight: Light? = nil
local bulbBaseBrightness = Config.Visual.BulbBrightness
local bulbBaseColor = Color3.fromRGB(255, 226, 180)
local roomLights: { LightRecord } = {}
local alarmParts: { PartRecord } = {}
local alarmLights: { LightRecord } = {}
local mirror: MirrorRecord? = nil

local tvStatic: StaticNoise.StaticNoise? = nil
local tvCategory: TextLabel? = nil
local tvAnswer: TextLabel? = nil
local crtNoise: { StaticNoise.StaticNoise } = {}

local musicWeight = 0
local idleClock = 0
local staticAccumulator = 0
local eliminationUntil = 0
local eliminationActive = false

local function findDeep(parent: Instance, name: string): Instance?
	return parent:FindFirstChild(name, true)
end

local function waitChild(parent: Instance, name: string): Instance?
	return parent:WaitForChild(name, WAIT_TIMEOUT)
end

local function recordLight(list: { LightRecord }, light: Light)
	table.insert(list, { light = light, color = light.Color, brightness = light.Brightness })
end

----------------------------------------------------------------------------
-- Mirror
----------------------------------------------------------------------------
local function applyMirror()
	local record = mirror
	if not record then
		return
	end
	local part = record.part
	if spectatorMode then
		part.Transparency = 0.6
		part.Reflectance = 0.03
		part.Material = Enum.Material.Glass
		part.Color = Color3.fromRGB(40, 46, 44)
	else
		part.Transparency = 0
		part.Reflectance = 0.5
		part.Material = Enum.Material.SmoothPlastic
		part.Color = Color3.fromRGB(22, 24, 26)
	end
end

local function restoreMirror()
	local record = mirror
	if not record or not record.part.Parent then
		return
	end
	record.part.Transparency = record.transparency
	record.part.Reflectance = record.reflectance
	record.part.Color = record.color
	record.part.Material = record.material
end

----------------------------------------------------------------------------
-- Elimination tint
----------------------------------------------------------------------------
local function setAlarm(on: boolean)
	for _, rec in roomLights do
		rec.light.Color = if on then RED else rec.color
	end
	for _, rec in alarmLights do
		rec.light.Color = if on then RED else rec.color
		rec.light.Enabled = on or rec.brightness > 0
		rec.light.Brightness = if on then math.max(rec.brightness, 2) else rec.brightness
	end
	for _, rec in alarmParts do
		rec.part.Color = if on then RED else rec.color
		rec.part.Material = if on then Enum.Material.Neon else rec.material
	end
	if bulbLight then
		bulbLight.Color = if on then RED else bulbBaseColor
	end
end

----------------------------------------------------------------------------
-- Per-frame
----------------------------------------------------------------------------
local function stepBulb(dt: number)
	local p, a, offset = pivot, assembly, assemblyOffset
	if not p or not a or not offset then
		return
	end
	local beat = MusicController.currentBeat()
	local target = if beat ~= nil then 1 else 0
	-- Exponential approach so the swing mode never snaps.
	musicWeight += (target - musicWeight) * math.min(1, dt / BLEND_SECONDS * 3)
	idleClock += dt

	local idleAngle = math.rad(Config.Visual.BulbIdleSwingDegrees) * math.sin(idleClock * 2 * math.pi / IDLE_PERIOD)
	-- cos(pi * beat): ±amplitude exactly on every beat, smooth in between.
	local musicAngle = if beat ~= nil then math.rad(Config.Visual.BulbSwingDegrees) * math.cos(math.pi * beat) else 0
	local angle = idleAngle + (musicAngle - idleAngle) * musicWeight
	a:PivotTo(p.CFrame * CFrame.Angles(0, 0, angle) * offset)

	local light = bulbLight
	if light then
		local pulse = 0
		if beat ~= nil and beat >= 0 then
			local phase = beat - math.floor(beat)
			pulse = Config.Visual.BulbBrightnessPulse * math.exp(-phase * 5)
		end
		light.Brightness = bulbBaseBrightness + pulse
	end
end

local function stepStatic(dt: number)
	staticAccumulator += dt
	local interval = 1 / Config.Visual.StaticFps
	if staticAccumulator < interval then
		return
	end
	staticAccumulator = 0
	local tv = tvStatic
	if tv then
		local showsText = (tvCategory ~= nil and tvCategory.Text ~= "") or (tvAnswer ~= nil and tvAnswer.Text ~= "")
		tv:setVisible(not showsText)
		tv:step()
	end
	for _, noise in crtNoise do
		noise:step()
	end
end

local function onRender(dt: number)
	stepBulb(dt)
	stepStatic(dt)
	if eliminationActive and os.clock() >= eliminationUntil then
		eliminationActive = false
		setAlarm(false)
	end
end

----------------------------------------------------------------------------
-- Setup (async: StreamingEnabled may deliver room parts late)
----------------------------------------------------------------------------
local function setupBulb(model: Model, myToken: number)
	local p = waitChild(model, Names.BulbPivot)
	local a = waitChild(model, Names.BulbAssembly)
	if myToken ~= token or not p or not a or not p:IsA("BasePart") or not a:IsA("Model") then
		return
	end
	pivot = p
	assembly = a
	-- Captured once: the bulb's pose relative to the hinge.
	assemblyOffset = p.CFrame:ToObjectSpace(a:GetPivot())
	local light = findDeep(a, Names.BulbLight)
	if light and light:IsA("Light") then
		bulbLight = light
		bulbBaseBrightness = light.Brightness
		bulbBaseColor = light.Color
	end
end

local function setupLights(model: Model, myToken: number)
	local folder = waitChild(model, Names.RoomLights)
	if myToken ~= token then
		return
	end
	if folder then
		for _, d in folder:GetDescendants() do
			if d:IsA("Light") then
				recordLight(roomLights, d)
			end
		end
	end
	local alarm = findDeep(model, ALARM_STRIP_NAME)
	if alarm then
		local candidates = alarm:GetDescendants()
		table.insert(candidates, alarm)
		for _, d in candidates do
			if d:IsA("BasePart") then
				table.insert(alarmParts, { part = d, color = d.Color, material = d.Material })
			elseif d:IsA("Light") then
				recordLight(alarmLights, d)
			end
		end
	end
end

local function setupMirror(model: Model, myToken: number)
	local part = waitChild(model, Names.TwoWayMirror)
	if myToken ~= token or not part or not part:IsA("BasePart") then
		return
	end
	mirror = {
		part = part,
		transparency = part.Transparency,
		reflectance = part.Reflectance,
		color = part.Color,
		material = part.Material,
	}
	applyMirror()
end

local function setupScreens(model: Model, myToken: number)
	local tvPart = waitChild(model, Names.TVScreen)
	if myToken ~= token then
		return
	end
	if tvPart then
		local gui = tvPart:WaitForChild(Names.TVGui, WAIT_TIMEOUT)
		local frame = gui and gui:WaitForChild(Names.TVFrame, WAIT_TIMEOUT)
		if myToken ~= token then
			return
		end
		if frame then
			local staticFrame = frame:FindFirstChild(Names.TVStatic)
			local category = frame:FindFirstChild(Names.TVCategory)
			local answer = frame:FindFirstChild(Names.TVAnswer)
			tvCategory = if category and category:IsA("TextLabel") then category else nil
			tvAnswer = if answer and answer:IsA("TextLabel") then answer else nil
			if staticFrame and staticFrame:IsA("GuiObject") then
				tvStatic = StaticNoise.new(staticFrame, 8, 6)
			end
		end
	end
	local crts = findDeep(model, Names.CRTs)
	if crts then
		for _, crt in crts:GetChildren() do
			local screen = if crt:IsA("BasePart") and crt.Name == Names.CRTScreen
				then crt
				else crt:FindFirstChild(Names.CRTScreen, true)
			if screen and screen:IsA("BasePart") then
				table.insert(crtNoise, StaticNoise.onPart(screen))
			end
		end
	end
end

function RoomFX.attach(model: Model)
	if room == model then
		return
	end
	RoomFX.detach()
	room = model
	token += 1
	local myToken = token
	musicWeight = 0
	table.insert(connections, RunService.RenderStepped:Connect(onRender))
	task.spawn(setupBulb, model, myToken)
	task.spawn(setupLights, model, myToken)
	task.spawn(setupMirror, model, myToken)
	task.spawn(setupScreens, model, myToken)
end

function RoomFX.detach()
	token += 1
	for _, c in connections do
		c:Disconnect()
	end
	table.clear(connections)
	if eliminationActive then
		eliminationActive = false
		setAlarm(false)
	end
	if bulbLight then
		bulbLight.Brightness = bulbBaseBrightness
	end
	restoreMirror()
	if tvStatic then
		tvStatic:destroy()
	end
	for _, noise in crtNoise do
		noise:destroy()
	end
	table.clear(crtNoise)
	table.clear(roomLights)
	table.clear(alarmParts)
	table.clear(alarmLights)
	room, pivot, assembly, assemblyOffset, bulbLight, mirror = nil, nil, nil, nil, nil, nil
	tvStatic, tvCategory, tvAnswer = nil, nil, nil
end

function RoomFX.setSpectator(isSpectator: boolean)
	if spectatorMode == isSpectator then
		return
	end
	spectatorMode = isSpectator
	applyMirror()
end

function RoomFX.pulseElimination()
	if not room then
		return
	end
	eliminationUntil = os.clock() + Config.Visual.EliminationPulseSeconds
	if not eliminationActive then
		eliminationActive = true
		setAlarm(true)
	end
end

return RoomFX
