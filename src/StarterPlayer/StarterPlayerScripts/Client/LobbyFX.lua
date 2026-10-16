--!strict
--[[
	LobbyFX  (ModuleScript)  ·  StarterPlayerScripts/Client/LobbyFX

	Lobby ambience, all client-local and cheap:
	  • fluorescent flicker (Lobby.Fluorescents)
	  • CRT static on Lobby.CRTs screens near the camera only
	  • queue elevator doors tweened from each QueueNN model's DoorsOpen attribute

	The per-frame work pauses while the player is in a match (setActive(false));
	door state keeps following the attributes either way.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage.Shared.Config)
local Names = require(ReplicatedStorage.Shared.Names)
local StaticNoise = require(script.Parent.StaticNoise)

local DOOR_TWEEN = TweenInfo.new(0.7, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut)
local DISTANCE_CHECK_INTERVAL = 0.5
local WAIT_TIMEOUT = 30

type Fixture = {
	lights: { Light },
	parts: { BasePart },
	materials: { Enum.Material },
	flickerUntil: number,
	off: boolean,
}
type Crt = { noise: StaticNoise.StaticNoise, part: BasePart, near: boolean }

local LobbyFX = {}

local active = true
local started = false
local fixtures: { Fixture } = {}
local crts: { Crt } = {}
local random = Random.new()
local staticAccumulator = 0
local distanceAccumulator = DISTANCE_CHECK_INTERVAL

----------------------------------------------------------------------------
-- Fluorescents
----------------------------------------------------------------------------
local function addFixture(instance: Instance)
	local fixture: Fixture = { lights = {}, parts = {}, materials = {}, flickerUntil = 0, off = false }
	local all = instance:GetDescendants()
	table.insert(all, instance)
	for _, d in all do
		if d:IsA("Light") then
			table.insert(fixture.lights, d)
		elseif d:IsA("BasePart") and d.Material == Enum.Material.Neon then
			table.insert(fixture.parts, d)
			table.insert(fixture.materials, d.Material)
		end
	end
	if #fixture.lights > 0 or #fixture.parts > 0 then
		table.insert(fixtures, fixture)
	end
end

local function setFixture(fixture: Fixture, off: boolean)
	fixture.off = off
	for _, light in fixture.lights do
		light.Enabled = not off
	end
	for i, part in fixture.parts do
		part.Material = if off then Enum.Material.SmoothPlastic else fixture.materials[i]
	end
end

local function stepFluorescents(now: number)
	for _, fixture in fixtures do
		if fixture.off then
			if now >= fixture.flickerUntil then
				setFixture(fixture, false)
			end
		elseif random:NextNumber() < Config.Visual.FluorescentFlickerChance then
			fixture.flickerUntil = now + random:NextNumber(0.04, 0.18)
			setFixture(fixture, true)
		end
	end
end

----------------------------------------------------------------------------
-- CRTs
----------------------------------------------------------------------------
local function addCrt(instance: Instance)
	local screen = if instance:IsA("BasePart") and instance.Name == Names.CRTScreen
		then instance
		else instance:FindFirstChild(Names.CRTScreen, true)
	if screen and screen:IsA("BasePart") then
		local noise = StaticNoise.onPart(screen)
		noise:setVisible(false)
		table.insert(crts, { noise = noise, part = screen, near = false })
	end
end

local function stepCrts(dt: number)
	distanceAccumulator += dt
	if distanceAccumulator >= DISTANCE_CHECK_INTERVAL then
		distanceAccumulator = 0
		local camera = Workspace.CurrentCamera
		local origin = if camera then camera.CFrame.Position else Vector3.zero
		for _, crt in crts do
			crt.near = (crt.part.Position - origin).Magnitude <= Config.Visual.StaticMaxDistance
			crt.noise:setVisible(crt.near)
		end
	end
	staticAccumulator += dt
	if staticAccumulator < 1 / Config.Visual.StaticFps then
		return
	end
	staticAccumulator = 0
	for _, crt in crts do
		if crt.near then
			crt.noise:step()
		end
	end
end

----------------------------------------------------------------------------
-- Queue doors
----------------------------------------------------------------------------
local function bindDoor(queue: Instance, door: BasePart)
	local closed = door.CFrame -- the generator builds doors closed
	local offset = door:GetAttribute(Names.AttrDoorOpenOffset)
	local open = if typeof(offset) == "Vector3" then closed * CFrame.new(offset) else closed
	local current: Tween? = nil
	local function apply(animate: boolean)
		local target = if queue:GetAttribute(Names.AttrDoorsOpen) == true then open else closed
		if current then
			current:Cancel()
			current = nil
		end
		if animate then
			local tween = TweenService:Create(door, DOOR_TWEEN, { CFrame = target })
			current = tween
			tween:Play()
		else
			door.CFrame = target
		end
	end
	apply(false)
	queue:GetAttributeChangedSignal(Names.AttrDoorsOpen):Connect(function()
		apply(true)
	end)
end

local function bindQueue(queue: Instance)
	local index = queue:GetAttribute(Names.AttrQueueIndex)
	if type(index) ~= "number" then
		local parsed = tonumber(string.match(queue.Name, "%d+") or "")
		if not parsed then
			return
		end
		index = parsed
	end
	local queueIndex = index :: number
	for _, name in { Names.QueueDoorLeft(queueIndex), Names.QueueDoorRight(queueIndex) } do
		task.spawn(function()
			local door = queue:WaitForChild(name, WAIT_TIMEOUT)
			if door and door:IsA("BasePart") then
				bindDoor(queue, door)
			end
		end)
	end
end

----------------------------------------------------------------------------
-- Boot
----------------------------------------------------------------------------
local function onRender(dt: number)
	if not active then
		return
	end
	stepFluorescents(os.clock())
	stepCrts(dt)
end

local function setup()
	local map = Workspace:WaitForChild(Names.Map)
	local lobby = map:WaitForChild(Names.Lobby, WAIT_TIMEOUT)
	if lobby then
		local fluorescents = lobby:WaitForChild(Names.Fluorescents, WAIT_TIMEOUT)
		if fluorescents then
			for _, child in fluorescents:GetChildren() do
				addFixture(child)
			end
			fluorescents.ChildAdded:Connect(addFixture)
		end
		local crtFolder = lobby:WaitForChild(Names.CRTs, WAIT_TIMEOUT)
		if crtFolder then
			for _, child in crtFolder:GetChildren() do
				addCrt(child)
			end
			crtFolder.ChildAdded:Connect(addCrt)
		end
	end
	local queues = map:WaitForChild(Names.Queues, WAIT_TIMEOUT)
	if queues then
		for _, queue in queues:GetChildren() do
			bindQueue(queue)
		end
		queues.ChildAdded:Connect(bindQueue)
	end
end

function LobbyFX.start()
	if started then
		return
	end
	started = true
	RunService.RenderStepped:Connect(onRender)
	task.spawn(setup)
end

-- Pauses flicker/static while the player is away in a match room.
function LobbyFX.setActive(isActive: boolean)
	if active == isActive then
		return
	end
	active = isActive
	if not isActive then
		for _, fixture in fixtures do
			if fixture.off then
				setFixture(fixture, false)
			end
		end
		for _, crt in crts do
			crt.near = false
			crt.noise:setVisible(false)
		end
		distanceAccumulator = DISTANCE_CHECK_INTERVAL
	end
end

return LobbyFX
