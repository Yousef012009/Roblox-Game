--!strict
--[[
	CameraController  (ModuleScript)  ·  StarterPlayerScripts/Client/CameraController

	Three camera modes:
	  Default    normal Roblox camera (lobby)
	  Room       fixed cinematic shot from Workspace.CameraPoints.RoomCam
	             (seated suspects + TV), with a slow handheld sway and a small
	             FOV "bump" on every beat
	  Spectator  fixed shot from CameraPoints.SpectatorCam, looking through
	             the two-way mirror

	THE TWO-WAY MIRROR is a trick done locally on each client: changing a
	part's properties from a LocalScript only affects that one player. Seated
	players see an opaque, reflective mirror; spectators see clear tinted
	glass.

	Mobile: the field of view widens on narrow or portrait screens so all
	four seats stay in frame.
]]

local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

export type Mode = "Default" | "Room" | "Spectator"

local BASE_FOV = 62 -- vertical FOV tuned for 16:9
local BLEND_SECONDS = 0.7

local CameraController = {}
CameraController.__index = CameraController

type MirrorLook = { Transparency: number, Reflectance: number, Color: Color3, Material: Enum.Material }

export type CameraController = typeof(setmetatable(
	{} :: {
		_mode: Mode,
		_blend: number,
		_blendFrom: CFrame,
		_bump: number,
		_mirror: BasePart?,
		_mirrorOriginal: MirrorLook?,
	},
	CameraController
))

local MIRROR_LOOKS: { [string]: MirrorLook } = {
	-- What a seated suspect sees: their own reflection (well, a dark shiny pane).
	Room = {
		Transparency = 0,
		Reflectance = 0.55,
		Color = Color3.fromRGB(70, 78, 92),
		Material = Enum.Material.SmoothPlastic,
	},
	-- What a spectator sees: a dim window into the room.
	Spectator = {
		Transparency = 0.62,
		Reflectance = 0.04,
		Color = Color3.fromRGB(90, 110, 140),
		Material = Enum.Material.Glass,
	},
}

local function findPoint(name: string): BasePart?
	local points = Workspace:FindFirstChild("CameraPoints")
	local point = points and points:FindFirstChild(name)
	return if point and point:IsA("BasePart") then point else nil
end

-- Keep the horizontal framing of a 16:9 shot on any aspect ratio.
local function fittedFov(camera: Camera): number
	local viewport = camera.ViewportSize
	if viewport.Y <= 0 then
		return BASE_FOV
	end
	local aspect = viewport.X / viewport.Y
	local reference = 16 / 9
	if aspect >= reference then
		return BASE_FOV
	end
	local halfH = math.atan(math.tan(math.rad(BASE_FOV) / 2) * reference)
	local vertical = 2 * math.deg(math.atan(math.tan(halfH) / aspect))
	return math.clamp(vertical, BASE_FOV, 100)
end

function CameraController.new(): CameraController
	local self = setmetatable({}, CameraController) :: any
	self._mode = "Default"
	self._blend = 1
	self._blendFrom = CFrame.identity
	self._bump = 0

	task.spawn(function()
		local room = Workspace:WaitForChild("InterrogationRoom", 30)
		local mirror = room and room:WaitForChild("TwoWayMirror", 10)
		if mirror and mirror:IsA("BasePart") then
			self._mirror = mirror
			self._mirrorOriginal = {
				Transparency = mirror.Transparency,
				Reflectance = mirror.Reflectance,
				Color = mirror.Color,
				Material = mirror.Material,
			}
			self:_applyMirror()
		end
	end)

	RunService:BindToRenderStep("C64Camera", Enum.RenderPriority.Camera.Value + 1, function(dt: number)
		self:_update(dt)
	end)
	return self
end

function CameraController._applyMirror(self: CameraController)
	local mirror = self._mirror
	local look = MIRROR_LOOKS[self._mode] or self._mirrorOriginal
	if not mirror or not look then
		return
	end
	mirror.Transparency = look.Transparency
	mirror.Reflectance = look.Reflectance
	mirror.Color = look.Color
	mirror.Material = look.Material
end

function CameraController.setMode(self: CameraController, mode: Mode)
	if mode == self._mode then
		return
	end
	local camera = Workspace.CurrentCamera
	self._mode = mode
	self:_applyMirror()

	if mode == "Default" then
		camera.CameraType = Enum.CameraType.Custom
		camera.FieldOfView = 70
		return
	end

	local point = findPoint(if mode == "Room" then "RoomCam" else "SpectatorCam")
	if not point then
		warn(`[Camera] Workspace.CameraPoints.{if mode == "Room" then "RoomCam" else "SpectatorCam"} is missing; using the default camera.`)
		camera.CameraType = Enum.CameraType.Custom
		return
	end
	self._blendFrom = camera.CFrame
	self._blend = 0
	camera.CameraType = Enum.CameraType.Scriptable
end

function CameraController.getMode(self: CameraController): Mode
	return self._mode
end

-- Called by RhythmController on every beat.
function CameraController.bump(self: CameraController, accent: boolean)
	if self._mode ~= "Default" then
		self._bump = if accent then 1 else 0.5
	end
end

function CameraController._update(self: CameraController, dt: number)
	if self._mode == "Default" then
		return
	end
	local camera = Workspace.CurrentCamera
	local point = findPoint(if self._mode == "Room" then "RoomCam" else "SpectatorCam")
	if not point then
		return
	end

	-- Ease from wherever the camera was into the fixed shot.
	self._blend = math.min(self._blend + dt / BLEND_SECONDS, 1)
	local alpha = 1 - (1 - self._blend) ^ 3

	-- Gentle "handheld" sway so the shot feels alive.
	local t = os.clock()
	local sway = CFrame.Angles(math.rad(math.sin(t * 0.7) * 0.35), math.rad(math.sin(t * 0.45) * 0.5), 0)
	local target = point.CFrame * sway

	camera.CameraType = Enum.CameraType.Scriptable
	camera.CFrame = if alpha < 1 then self._blendFrom:Lerp(target, alpha) else target

	self._bump = math.max(self._bump - dt * 5, 0)
	camera.FieldOfView = fittedFov(camera) - self._bump * 1.6
end

return CameraController
