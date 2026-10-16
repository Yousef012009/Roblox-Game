--!strict
--[[
	CameraController  (ModuleScript)  ·  StarterPlayerScripts/Client/CameraController

	Modes:
	  Lobby        default Custom camera following the humanoid, FOV 70
	  Intro        IntroCamera → InterrogationCamera dolly (Config.Camera.IntroDollySeconds)
	  Room         InterrogationCamera (Caller while judging: CallerCamera), subtle sway
	  Spectator    one of Names.SpectatorCameras (cycle with cycleSpectator)
	  Victory      VictoryCamera, slowly orbiting (a gentle arc) and dollying in
	               toward the winner's seat (setVictoryFocus) or the table

	Every pose comes from the named anchor Parts of the player's own room
	(the anchor's CFrame is the camera pose). Sway is disabled while a local
	TextBox has focus. A missing anchor falls back to the next sensible one,
	and with no anchors at all the camera simply stays where it is.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage.Shared.Config)
local Names = require(ReplicatedStorage.Shared.Names)

export type Mode = "Lobby" | "Intro" | "Room" | "Spectator" | "Victory"

local CameraController = {}

local BIND_NAME = "C64Camera"
local LOBBY_FOV = 70
local REFERENCE_ASPECT = 16 / 9
local JOLT_SECONDS = 0.45
local VICTORY_ARC = math.rad(10) -- orbit swing either side of the anchor
local VICTORY_ARC_SPEED = 0.22 -- rad/s of the swing phase
local VICTORY_DOLLY = 0.2 -- fraction of the distance closed by the dolly
local VICTORY_DOLLY_SECONDS = 8
local VICTORY_FOCUS_DISTANCE = 14 -- fallback focus: this far along the anchor's look

local mode: Mode = "Lobby"
local room: Model? = nil
local useCallerCamera = false
local typing = false
local bound = false

local currentCFrame: CFrame? = nil
local introStartedAt = 0
local victoryStartedAt = 0
local victoryFocus: Vector3? = nil
local spectatorIndex = 1
local joltUntil = 0
local swayClock = 0
local fovCache = Config.Camera.FieldOfView
local cachedViewport = Vector2.zero

local function anchors(): Instance?
	local model = room
	return if model then model:FindFirstChild(Names.CameraAnchors, true) else nil
end

local function anchorCFrame(name: string): CFrame?
	local folder = anchors()
	local part = folder and folder:FindFirstChild(name)
	if part and part:IsA("BasePart") then
		return part.CFrame
	end
	return nil
end

-- Spectator anchors that actually exist in this room (order of Names list).
-- Cached and refreshed once a second (anchors may stream in late), so the
-- render step never allocates.
local spectatorList: { string } = {}
local spectatorListAt = -math.huge
local function spectatorAnchors(): { string }
	local now = os.clock()
	if now - spectatorListAt < 1 then
		return spectatorList
	end
	spectatorListAt = now
	local list = spectatorList
	table.clear(list)
	local folder = anchors()
	if folder then
		for _, name in Names.SpectatorCameras do
			if folder:FindFirstChild(name) then
				table.insert(list, name)
			end
		end
	end
	return list
end

-- Keeps the horizontal framing of a 16:9 shot on narrower (portrait) screens.
local function fittedFov(camera: Camera): number
	local viewport = camera.ViewportSize
	if viewport == cachedViewport then
		return fovCache
	end
	cachedViewport = viewport
	local base = Config.Camera.FieldOfView
	local aspect = if viewport.Y > 0 then viewport.X / viewport.Y else REFERENCE_ASPECT
	if aspect >= REFERENCE_ASPECT then
		fovCache = base
	else
		local halfH = math.atan(math.tan(math.rad(base) / 2) * REFERENCE_ASPECT)
		local vertical = 2 * math.deg(math.atan(math.tan(halfH) / aspect))
		fovCache = math.clamp(vertical, base, Config.Camera.MaxFieldOfView)
	end
	return fovCache
end

local function targetCFrame(now: number): CFrame?
	if mode == "Intro" then
		local from = anchorCFrame(Names.IntroCamera)
		local to = anchorCFrame(Names.InterrogationCamera)
		if from and to then
			local t = math.clamp((now - introStartedAt) / Config.Camera.IntroDollySeconds, 0, 1)
			local eased = t * t * (3 - 2 * t) -- smoothstep
			return from:Lerp(to, eased)
		end
		return to or from
	elseif mode == "Room" then
		if useCallerCamera then
			local caller = anchorCFrame(Names.CallerCamera)
			if caller then
				return caller
			end
		end
		return anchorCFrame(Names.InterrogationCamera)
	elseif mode == "Spectator" then
		local list = spectatorAnchors()
		if #list == 0 then
			return anchorCFrame(Names.InterrogationCamera)
		end
		spectatorIndex = ((spectatorIndex - 1) % #list) + 1
		return anchorCFrame(list[spectatorIndex])
	elseif mode == "Victory" then
		local base = anchorCFrame(Names.VictoryCamera) or anchorCFrame(Names.InterrogationCamera)
		if not base then
			return nil
		end
		local focus = victoryFocus or (base.Position + base.LookVector * VICTORY_FOCUS_DISTANCE)
		local t = now - victoryStartedAt
		local angle = VICTORY_ARC * math.sin(t * VICTORY_ARC_SPEED)
		local d = math.clamp(t / VICTORY_DOLLY_SECONDS, 0, 1)
		local dolly = 1 - VICTORY_DOLLY * d * d * (3 - 2 * d)
		local offset = (base.Position - focus) * dolly
		local position = focus + CFrame.Angles(0, angle, 0):VectorToWorldSpace(offset)
		return CFrame.lookAt(position, focus)
	end
	return nil
end

local function step(dt: number)
	local camera = Workspace.CurrentCamera
	if not camera or mode == "Lobby" then
		return
	end
	local now = os.clock()
	local target = targetCFrame(now)
	if not target then
		return -- room not streamed in yet: leave the camera alone
	end
	if camera.CameraType ~= Enum.CameraType.Scriptable then
		camera.CameraType = Enum.CameraType.Scriptable
	end

	local from = currentCFrame or target
	local blended
	if mode == "Intro" then
		blended = target -- the dolly is already a scripted path
	else
		-- Framerate-independent exponential blend; reaches ~95 % in BlendSeconds.
		local alpha = 1 - math.exp(-dt * 3 / Config.Camera.BlendSeconds)
		blended = from:Lerp(target, alpha)
	end
	currentCFrame = blended

	local final = blended
	if not typing then
		swayClock += dt
		local sway = math.rad(Config.Camera.SwayDegrees)
		final *= CFrame.Angles(sway * math.sin(swayClock * 0.7), sway * math.sin(swayClock * 0.45 + 1.3), 0)
	end
	if now < joltUntil then
		local k = (joltUntil - now) / JOLT_SECONDS
		local amp = 0.35 * k * k
		final *= CFrame.new(math.sin(now * 61) * amp, math.sin(now * 47) * amp, 0)
			* CFrame.Angles(0, 0, math.sin(now * 53) * math.rad(3) * k)
	end
	camera.CFrame = final
	local fov = fittedFov(camera)
	if camera.FieldOfView ~= fov then
		camera.FieldOfView = fov
	end
end

local function restoreLobbyCamera()
	local camera = Workspace.CurrentCamera
	if not camera then
		return
	end
	camera.CameraType = Enum.CameraType.Custom
	local character = Players.LocalPlayer.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		camera.CameraSubject = humanoid
	end
	camera.FieldOfView = LOBBY_FOV
end

function CameraController.setRoom(model: Model?)
	room = model
	spectatorListAt = -math.huge
end

function CameraController.setMode(newMode: Mode)
	if newMode == mode then
		return
	end
	local previous = mode
	mode = newMode
	if newMode == "Lobby" then
		if bound then
			RunService:UnbindFromRenderStep(BIND_NAME)
			bound = false
		end
		currentCFrame = nil
		restoreLobbyCamera()
		return
	end
	if newMode == "Intro" then
		introStartedAt = os.clock()
	elseif newMode == "Victory" then
		victoryStartedAt = os.clock()
	end
	if previous == "Lobby" then
		currentCFrame = nil -- cut, don't blend from the lobby
	end
	if not bound then
		RunService:BindToRenderStep(BIND_NAME, Enum.RenderPriority.Camera.Value + 1, step)
		bound = true
	end
end

function CameraController.getMode(): Mode
	return mode
end

-- World point the victory shot orbits / dollies toward (nil = the anchor's view).
function CameraController.setVictoryFocus(point: Vector3?)
	victoryFocus = point
end

function CameraController.setCallerFocus(on: boolean)
	useCallerCamera = on
end

function CameraController.setTyping(isTyping: boolean)
	typing = isTyping
end

function CameraController.cycleSpectator(direction: number)
	local count = #spectatorAnchors()
	if count > 0 then
		spectatorIndex = ((spectatorIndex - 1 + direction) % count) + 1
	end
end

function CameraController.spectatorLabel(): string
	local count = #spectatorAnchors()
	if count == 0 then
		return "CAM --"
	end
	return string.format("CAM %02d/%02d", ((spectatorIndex - 1) % count) + 1, count)
end

function CameraController.jolt()
	joltUntil = os.clock() + JOLT_SECONDS
end

-- Re-applies the lobby camera after a respawn (CameraSubject changes).
function CameraController.onCharacterAdded()
	if mode == "Lobby" then
		task.defer(restoreLobbyCamera)
	end
end

return CameraController
