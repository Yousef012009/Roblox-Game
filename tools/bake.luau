-- Usage (needs Lune 0.8.x and Rojo 7.x):
--   rojo build default.project.json -o base.rbxlx
--   lune run tools/bake.luau base.rbxlx Concentration64_Baked.rbxl
-- Offline baker: runs the game's real MapBuilder in Lune against the Rojo-built
-- place and saves a place file with Workspace.Map + the room template baked in.
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")
local roblox = require("@lune/roblox")
local task = require("@lune/task")

local input, output = process.args[1], process.args[2]
local game = roblox.deserializePlace(fs.readFile(input))
local Instance, CFrame, Vector3 = roblox.Instance, roblox.CFrame, roblox.Vector3

-- Model pivots (not implemented by Lune): keep WorldPivot ourselves.
local pivots = setmetatable({}, { __mode = "k" })
local function getPivot(model)
	if model.PrimaryPart then
		return model.PrimaryPart.CFrame
	end
	return pivots[model] or CFrame.identity
end
roblox.implementProperty("Model", "WorldPivot", function(model)
	return pivots[model] or CFrame.identity
end, function(model, value)
	pivots[model] = value
end)
roblox.implementMethod("Model", "GetPivot", getPivot)
roblox.implementMethod("Model", "PivotTo", function(model, target)
	local delta = target * getPivot(model):Inverse()
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			d.CFrame = delta * d.CFrame
		end
	end
	if not model.PrimaryPart then
		pivots[model] = target
	end
end)
roblox.implementMethod("RunService", "IsRunning", function()
	return false
end)

-- Derived BasePart properties Lune does not compute.
for _, class in { "Part", "Seat", "SpawnLocation", "WedgePart", "CornerWedgePart", "TrussPart", "VehicleSeat" } do
	roblox.implementProperty(class, "Position", function(part)
		return part.CFrame.Position
	end, function(part, value)
		part.CFrame = CFrame.new(value) * part.CFrame.Rotation
	end)
end

-- Deterministic Random (Lune has none).
local Random = {}
Random.__index = Random
function Random.new(seed)
	return setmetatable({ s = (seed or 1) % 2147483647 }, Random)
end
function Random:_next()
	self.s = (self.s * 48271) % 2147483647
	return self.s / 2147483647
end
function Random:NextNumber(a, b)
	local r = self:_next()
	if a == nil then
		return r
	end
	return a + (b - a) * r
end
function Random:NextInteger(a, b)
	return math.floor(a + (b - a + 1) * self:_next())
end

-- Lune's CFrame.lookAt flips the Z axis; use Roblox's exact definition.
local function lookAt(pos, target, up)
	up = up or Vector3.yAxis
	local look = (target - pos).Unit
	local right = look:Cross(up).Unit
	return CFrame.fromMatrix(pos, right, right:Cross(look), -look)
end
local FixedCFrame = setmetatable({ lookAt = lookAt }, { __index = CFrame })

local cache = {}
local env
local function makeEnv(module)
	local t = {}
	for k, v in roblox do
		t[k] = v
	end
	for k, v in env do
		t[k] = v
	end
	t.script = module
	t.CFrame = FixedCFrame
	return t
end
local function req(module)
	if cache[module] ~= nil then
		return cache[module]
	end
	local fn = luau.load(module.Source, {
		debugName = module:GetFullName(),
		environment = makeEnv(module),
	})
	local result = fn()
	cache[module] = result
	return result
end
env = {
	game = game,
	workspace = game:GetService("Workspace"),
	Instance = Instance,
	Random = Random,
	task = task,
	require = req,
	warn = function(...)
		print("WARN", ...)
	end,
}

local mapBuilder = game:GetService("ServerScriptService").MapGen.MapBuilder
local map = req(mapBuilder).Bake()
local parts = 0
for _, d in map:GetDescendants() do
	if d:IsA("BasePart") then
		parts += 1
	end
end
print("baked parts:", parts, "template:", game:GetService("ServerStorage"):FindFirstChild("InterrogationModuleTemplate") ~= nil)
fs.writeFile(output, roblox.serializePlace(game))
print("wrote", output)
