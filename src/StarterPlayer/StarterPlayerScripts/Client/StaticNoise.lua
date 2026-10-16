--!strict
--[[
	StaticNoise  (ModuleScript)  ·  StarterPlayerScripts/Client/StaticNoise

	Cheap CRT "snow": a grid of at most 48 flat Frames whose grey levels are
	re-rolled a few times per second (Config.Visual.StaticFps, driven by the
	owner). No textures, no per-step allocations.
]]

local StaticNoise = {}
StaticNoise.__index = StaticNoise

local MAX_CELLS = 48

export type StaticNoise = typeof(setmetatable(
	{} :: {
		root: Frame,
		cells: { Frame },
		random: Random,
		ownsGui: SurfaceGui?,
	},
	StaticNoise
))

-- Builds the grid inside `container` (a GuiObject or SurfaceGui).
function StaticNoise.new(container: Instance, cols: number?, rows: number?): StaticNoise
	local c = cols or 8
	local r = rows or 6
	while c * r > MAX_CELLS do
		r -= 1
	end
	local root = Instance.new("Frame")
	root.Name = "C64Static"
	root.BackgroundColor3 = Color3.fromRGB(18, 20, 18)
	root.BackgroundTransparency = 0
	root.BorderSizePixel = 0
	root.Size = UDim2.fromScale(1, 1)
	root.ZIndex = 5
	local cells = table.create(c * r)
	for y = 0, r - 1 do
		for x = 0, c - 1 do
			local cell = Instance.new("Frame")
			cell.BorderSizePixel = 0
			cell.Position = UDim2.fromScale(x / c, y / r)
			cell.Size = UDim2.fromScale(1 / c, 1 / r)
			cell.ZIndex = 6
			cell.Parent = root
			table.insert(cells, cell)
		end
	end
	root.Parent = container
	local self = setmetatable({ root = root, cells = cells, random = Random.new(), ownsGui = nil }, StaticNoise)
	self:step()
	return self
end

-- For a 3D screen Part: reuses an existing SurfaceGui or makes a local one.
function StaticNoise.onPart(part: BasePart): StaticNoise
	local gui = part:FindFirstChildOfClass("SurfaceGui")
	local owned: SurfaceGui? = nil
	if not gui then
		local created = Instance.new("SurfaceGui")
		created.Name = "C64StaticGui"
		created.Face = Enum.NormalId.Front
		created.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
		created.PixelsPerStud = 20
		created.LightInfluence = 0
		created.Parent = part
		gui = created
		owned = created
	end
	local noise = StaticNoise.new(gui :: SurfaceGui)
	noise.ownsGui = owned
	return noise
end

function StaticNoise.step(self: StaticNoise)
	if not self.root.Visible then
		return
	end
	local random = self.random
	for _, cell in self.cells do
		local v = random:NextNumber(0.05, 0.55)
		cell.BackgroundColor3 = Color3.new(v, v, v * 1.04)
	end
end

function StaticNoise.setVisible(self: StaticNoise, visible: boolean)
	if self.root.Visible ~= visible then
		self.root.Visible = visible
	end
end

function StaticNoise.destroy(self: StaticNoise)
	self.root:Destroy()
	if self.ownsGui then
		self.ownsGui:Destroy()
	end
end

return StaticNoise
