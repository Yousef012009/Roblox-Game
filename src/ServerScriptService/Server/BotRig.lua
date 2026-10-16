--!strict
--[[
	BotRig  (ModuleScript)  ·  ServerScriptService/Server/BotRig

	The body of one AI detective: a humanoid model in the match room with a
	floating name tag and server-side animations.

	    local description = BotRig.randomDescription(rng)        noir colours, no assets
	    local model = BotRig.modelFromDescription(description)   YIELDS; nil on failure
	    local model = BotRig.blockModel(description)             never fails, never yields
	    local rig = BotRig.new(model, name, parent, cframe)
	    rig:seat(seat) · rig:teleport(cframe) · rig:play("Cheer") · rig:destroy()

	BODY
	  Players:CreateHumanoidModelFromDescriptionAsync (R15) inside pcall; the
	  caller falls back to blockModel (Humanoid + HumanoidRootPart + Torso +
	  Head, welded) so a bot always has a body. The model is pivoted BEFORE
	  it is parented, can't walk or jump, never dies, and hides the default
	  humanoid name (the BillboardGui "AI · <name>" replaces it).

	ANIMATIONS (Config.Animations; "" = off)
	  Played through Humanoid.Animator (created when missing). Loading or
	  playing a track is wrapped in pcall; an id that fails once is not
	  retried. Sit is looped at Idle priority while seated; the rest are
	  one-shots at Action priority over it.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage.Shared.Config)

local CharacterUtil = require(script.Parent.CharacterUtil)

export type AnimationName = "Sit" | "Cheer" | "Point" | "Wave" | "Laugh"

local TAG_NAME = "BotNameTag"
local TAG_MAX_DISTANCE = 60
local TAG_COLOR = Color3.fromRGB(128, 168, 124) -- muted phosphor green
local TAG_STROKE = Color3.fromRGB(8, 12, 8)
local TAG_TEXT_SIZE = 13
local TAG_SIZE = UDim2.fromOffset(170, 20)
local TAG_OFFSET = Vector3.new(0, 1.9, 0)
local BLOCK_HIP_HEIGHT = 2

-- Skin tones, trench coats / suits, trousers: a muted 1940s palette.
local SKIN_TONES = {
	Color3.fromRGB(234, 192, 160),
	Color3.fromRGB(204, 158, 122),
	Color3.fromRGB(160, 114, 82),
	Color3.fromRGB(118, 80, 56),
	Color3.fromRGB(84, 58, 42),
}
local COATS = {
	Color3.fromRGB(150, 128, 96), -- camel trench
	Color3.fromRGB(112, 100, 82), -- khaki
	Color3.fromRGB(58, 60, 64), -- charcoal
	Color3.fromRGB(44, 50, 64), -- midnight navy
	Color3.fromRGB(86, 64, 50), -- tobacco brown
	Color3.fromRGB(96, 98, 92), -- slate
	Color3.fromRGB(70, 40, 38), -- oxblood
}
local TROUSERS = {
	Color3.fromRGB(30, 30, 34),
	Color3.fromRGB(46, 44, 42),
	Color3.fromRGB(56, 50, 44),
	Color3.fromRGB(38, 42, 52),
}

type RigData = {
	name: string,
	model: Model,
	humanoid: Humanoid,
	tracks: { [string]: AnimationTrack },
	failed: { [string]: boolean },
	destroyed: boolean,
}

local BotRig = {}
BotRig.__index = BotRig

export type BotRig = typeof(setmetatable({} :: RigData, BotRig))

local function pick(rng: Random, list: { Color3 }): Color3
	return list[rng:NextInteger(1, #list)]
end

-- A HumanoidDescription with randomised noir colours (no catalogue assets).
function BotRig.randomDescription(rng: Random): HumanoidDescription
	local description = Instance.new("HumanoidDescription")
	local skin = pick(rng, SKIN_TONES)
	local coat = pick(rng, COATS)
	local trousers = pick(rng, TROUSERS)
	description.HeadColor = skin
	description.TorsoColor = coat
	description.LeftArmColor = coat
	description.RightArmColor = coat
	description.LeftLegColor = trousers
	description.RightLegColor = trousers
	return description
end

-- R15 model built by the engine. YIELDS. nil if the call fails or returns
-- something without a Humanoid and a HumanoidRootPart.
function BotRig.modelFromDescription(description: HumanoidDescription): Model?
	local ok, result = pcall(function(): Model
		return Players:CreateHumanoidModelFromDescriptionAsync(description, Enum.HumanoidRigType.R15)
	end)
	if not ok then
		warn(`[BotRig] CreateHumanoidModelFromDescriptionAsync failed: {result}; using a block rig`)
		return nil
	end
	local model = result
	if model:FindFirstChildOfClass("Humanoid") and model:FindFirstChild("HumanoidRootPart") then
		return model
	end
	model:Destroy()
	return nil
end

local function blockPart(name: string, size: Vector3, cframe: CFrame, color: Color3, parent: Model): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.CFrame = cframe
	part.Color = color
	part.Material = Enum.Material.SmoothPlastic
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.CanCollide = false
	part.Parent = parent
	return part
end

local function weld(part0: BasePart, part1: BasePart)
	local constraint = Instance.new("WeldConstraint")
	constraint.Part0 = part0
	constraint.Part1 = part1
	constraint.Parent = part0
end

-- Fallback body: Humanoid + HumanoidRootPart + Torso + Head, welded together.
function BotRig.blockModel(description: HumanoidDescription): Model
	local model = Instance.new("Model")
	local root = blockPart("HumanoidRootPart", Vector3.new(2, 2, 1), CFrame.new(0, 3, 0), description.TorsoColor, model)
	root.Transparency = 1
	local torso = blockPart("Torso", Vector3.new(2, 2, 1), CFrame.new(0, 3, 0), description.TorsoColor, model)
	local head = blockPart("Head", Vector3.new(1.2, 1.2, 1.2), CFrame.new(0, 4.6, 0), description.HeadColor, model)
	weld(root, torso)
	weld(torso, head)
	local humanoid = Instance.new("Humanoid")
	humanoid.RigType = Enum.HumanoidRigType.R6
	humanoid.RequiresNeck = false
	humanoid.HipHeight = BLOCK_HIP_HEIGHT
	humanoid.Parent = model
	model.PrimaryPart = root
	return model
end

local function addNameTag(model: Model, name: string)
	local head = model:FindFirstChild("Head")
	local anchor = if head and head:IsA("BasePart") then head else model.PrimaryPart
	if not anchor then
		return
	end
	local gui = Instance.new("BillboardGui")
	gui.Name = TAG_NAME
	gui.Adornee = anchor
	gui.Size = TAG_SIZE
	gui.StudsOffset = TAG_OFFSET
	gui.MaxDistance = TAG_MAX_DISTANCE
	gui.AlwaysOnTop = false
	gui.LightInfluence = 0
	gui.ResetOnSpawn = false
	local label = Instance.new("TextLabel")
	label.Name = "Name"
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.Code
	label.TextSize = TAG_TEXT_SIZE
	label.TextColor3 = TAG_COLOR
	label.TextStrokeColor3 = TAG_STROKE
	label.TextStrokeTransparency = 0.45
	label.TextTransparency = 0.1
	label.Text = `AI · {name}`
	label.Parent = gui
	gui.Parent = anchor
end

-- Takes ownership of `model` (from modelFromDescription or blockModel),
-- places it at `cframe` and parents it under `parent`.
function BotRig.new(model: Model, name: string, parent: Instance, cframe: CFrame): BotRig
	-- modelFromDescription / blockModel always provide a Humanoid; keep the contract total anyway.
	local humanoid: Humanoid = model:FindFirstChildOfClass("Humanoid") or Instance.new("Humanoid")
	humanoid.Parent = model

	model.Name = name
	humanoid.DisplayName = name
	humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	humanoid.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff
	humanoid.WalkSpeed = 0
	humanoid.JumpPower = 0
	humanoid.JumpHeight = 0
	humanoid.BreakJointsOnDeath = false
	humanoid:SetStateEnabled(Enum.HumanoidStateType.Dead, false)
	if not humanoid:FindFirstChildOfClass("Animator") then
		local animator = Instance.new("Animator")
		animator.Parent = humanoid
	end
	-- Engine-built rigs ship an Animate script meant for players; bots are animated here.
	local animate = model:FindFirstChild("Animate")
	if animate then
		animate:Destroy()
	end
	addNameTag(model, name)

	model:PivotTo(cframe)
	model.Parent = parent
	-- Keep the body's physics on the server (no nearby client may push it
	-- around). Only possible while it is not yet welded to an anchored seat.
	local root = model:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") and root:IsDescendantOf(Workspace) and root:CanSetNetworkOwnership() then
		pcall(function()
			root:SetNetworkOwner(nil)
		end)
	end

	local self: RigData = {
		name = name,
		model = model,
		humanoid = humanoid,
		tracks = {},
		failed = {},
		destroyed = false,
	}
	return setmetatable(self, BotRig)
end

function BotRig.isAlive(self: BotRig): boolean
	return not self.destroyed and self.model.Parent ~= nil and self.humanoid.Parent == self.model
end

function BotRig.getHumanoid(self: BotRig): Humanoid?
	return if self:isAlive() then self.humanoid else nil
end

----------------------------------------------------------------------------
-- Animations
----------------------------------------------------------------------------

local function animationId(name: AnimationName): string
	local ids: { [string]: string } = Config.Animations :: any
	return ids[name] or ""
end

function BotRig.track(self: BotRig, name: AnimationName): AnimationTrack?
	local cached = self.tracks[name]
	if cached then
		return cached
	end
	if self.failed[name] or not self:isAlive() then
		return nil
	end
	local id = animationId(name)
	if id == "" then
		return nil
	end
	local humanoid = self.humanoid
	local animator: Animator = humanoid:FindFirstChildOfClass("Animator") or Instance.new("Animator")
	animator.Parent = humanoid
	local animation = Instance.new("Animation")
	animation.Name = name
	animation.AnimationId = id
	local ok, result = pcall(function(): AnimationTrack
		return animator:LoadAnimation(animation)
	end)
	if not ok then
		self.failed[name] = true
		warn(`[BotRig] {self.name}: animation {name} ({id}) failed to load: {result}`)
		return nil
	end
	local loaded = result
	loaded.Priority = if name == "Sit" then Enum.AnimationPriority.Idle else Enum.AnimationPriority.Action
	loaded.Looped = name == "Sit"
	self.tracks[name] = loaded
	return loaded
end

-- Plays `name` (Sit loops; the others play once). Never throws.
function BotRig.play(self: BotRig, name: AnimationName)
	local track = self:track(name)
	if not track then
		return
	end
	if name == "Sit" and track.IsPlaying then
		return
	end
	local ok, err = pcall(function()
		track:Play()
	end)
	if not ok then
		self.failed[name] = true
		self.tracks[name] = nil
		warn(`[BotRig] {self.name}: animation {name} failed to play: {err}`)
	end
end

function BotRig.stop(self: BotRig, name: AnimationName)
	local track = self.tracks[name]
	if track and track.IsPlaying then
		pcall(function()
			track:Stop()
		end)
	end
end

----------------------------------------------------------------------------
-- Placement
----------------------------------------------------------------------------

-- Sits the bot in `seat` and loops the Sit animation. False if the rig is gone.
function BotRig.seat(self: BotRig, seat: Seat): boolean
	if not self:isAlive() then
		return false
	end
	if not CharacterUtil.seatCharacter(self.model, self.humanoid, seat) then
		return false
	end
	self:play("Sit")
	return true
end

-- Stands the bot up and moves it to `cframe` (the lounge, a fallback spot).
function BotRig.teleport(self: BotRig, cframe: CFrame): boolean
	if not self:isAlive() then
		return false
	end
	self:stop("Sit")
	return CharacterUtil.teleportCharacter(self.model, cframe)
end

function BotRig.isSeatedIn(self: BotRig, seat: Seat): boolean
	return self:isAlive() and seat.Occupant == self.humanoid
end

function BotRig.destroy(self: BotRig)
	if self.destroyed then
		return
	end
	self.destroyed = true
	for _, track in self.tracks do
		pcall(function()
			track:Stop(0)
		end)
	end
	table.clear(self.tracks)
	self.model:Destroy()
end

return BotRig
