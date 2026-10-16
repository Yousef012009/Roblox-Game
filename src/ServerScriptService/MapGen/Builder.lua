--!strict
--[[
	Builder  (ModuleScript)  ·  ServerScriptService/MapGen/Builder

	Primitive factories for the procedural map. Everything the generator makes
	goes through here, so every part gets the same treatment:

	  • Anchored, smooth surfaces, Size set before CFrame, Parent set last.
	  • `flags.decor = true` marks small decorative pieces: no collision, no
	    raycast queries, no touch events, no shadow casting (cheap on phones).
	  • A global part counter drives cooperative yielding: when the build runs
	    inside a live game, Builder yields one frame every `yieldEvery` parts so
	    generation never trips the script-timeout watchdog. In Studio edit mode
	    (command-bar baking) yielding is disabled.

	Coordinate conventions used by every MapGen module:
	  • Y is up. Floors have their top surface at Y = 0.2.
	  • A prop is built around a LOCAL origin on the floor (y = 0) and faces
	    -Z (its pivot's LookVector); it is then pivoted into place.
	  • Cylinders run along the part's local X axis (Roblox convention); use
	    Builder.AxisY / Builder.AxisZ to stand them up or point them forward.
]]

local RunService = game:GetService("RunService")

local Palette = require(script.Parent.Palette)

type Swatch = Palette.Swatch

export type PartFlags = {
	decor: boolean?, -- small decoration: CanCollide/CanQuery/CanTouch/CastShadow all false
	collide: boolean?, -- explicit CanCollide override
	shadow: boolean?, -- explicit CastShadow override
	query: boolean?, -- explicit CanQuery override
	transparency: number?,
	reflectance: number?,
	color: Color3?, -- overrides the swatch colour
	material: Enum.Material?, -- overrides the swatch material
}

-- An opening cut through a wall, in wall-local units: `center` along the
-- wall's local X, `bottom`/`top` measured up from the wall's base.
export type Opening = {
	center: number,
	width: number,
	bottom: number,
	top: number,
}

export type TextOptions = {
	font: Enum.Font?,
	color: Color3?,
	background: Color3?,
	backgroundTransparency: number?, -- default 1 (no background) unless `background` is given
	pixelsPerStud: number?,
	lightInfluence: number?,
	brightness: number?,
	strokeTransparency: number?,
	strokeColor: Color3?,
	xAlignment: Enum.TextXAlignment?,
	name: string?,
	guiName: string?,
	padding: number?, -- scale padding on every side (0..0.5)
}

export type LightOptions = {
	name: string?,
	color: Color3,
	brightness: number,
	range: number,
	shadows: boolean?,
	enabled: boolean?,
	face: Enum.NormalId?, -- Spot / Surface lights
	angle: number?, -- Spot / Surface lights
}

local Builder = {}

-- Rotations that re-aim a cylinder's axis (local X) along another axis.
Builder.AxisY = CFrame.Angles(0, 0, math.rad(90)) -- local X → world-up
Builder.AxisZ = CFrame.Angles(0, math.rad(90), 0) -- local X → -Z (the prop's front)

----------------------------------------------------------------------------
-- Build session bookkeeping (part counting + cooperative yielding)
----------------------------------------------------------------------------
local partCount = 0
local yieldEvery = 0

-- Call once at the start of a build. Yields only while a game is running
-- (Play/Run or a live server); never from the Studio command bar.
function Builder.BeginSession(partsPerYield: number?)
	partCount = 0
	yieldEvery = if RunService:IsRunning() then (partsPerYield or 300) else 0
end

function Builder.GetPartCount(): number
	return partCount
end

local function countPart()
	partCount += 1
	if yieldEvery > 0 and partCount % yieldEvery == 0 then
		task.wait()
	end
end

----------------------------------------------------------------------------
-- Containers
----------------------------------------------------------------------------

-- A Model whose pivot is the local origin, so parts can be authored in local
-- coordinates and the whole thing placed with Model:PivotTo afterwards.
function Builder.newModel(name: string, parent: Instance?): Model
	local model = Instance.new("Model")
	model.Name = name
	model.WorldPivot = CFrame.identity
	model.Parent = parent
	return model
end

function Builder.newFolder(name: string, parent: Instance?): Folder
	local folder = Instance.new("Folder")
	folder.Name = name
	folder.Parent = parent
	return folder
end

-- Returns the existing child Folder called `name`, creating it if needed.
function Builder.getFolder(parent: Instance, name: string): Folder
	local existing = parent:FindFirstChild(name)
	if existing and existing:IsA("Folder") then
		return existing
	end
	return Builder.newFolder(name, parent)
end

-- Pivots a model built at the local origin into place, then parents it.
function Builder.place(model: Model, cf: CFrame, parent: Instance?): Model
	model:PivotTo(cf)
	model.Parent = parent
	return model
end

----------------------------------------------------------------------------
-- Parts
----------------------------------------------------------------------------
local NO_FLAGS: PartFlags = table.freeze({})

-- Shared property setup for every BasePart we create. Parent is set last.
local function setup(
	part: BasePart,
	parent: Instance?,
	name: string,
	size: Vector3,
	cf: CFrame,
	swatch: Swatch,
	flags: PartFlags?
): ()
	local f = flags or NO_FLAGS
	local decor = f.decor == true
	part.Name = name
	part.Anchored = true
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Size = size
	part.CFrame = cf
	part.Color = f.color or swatch.Color
	part.Material = f.material or swatch.Material
	part.Transparency = f.transparency or 0
	part.Reflectance = f.reflectance or 0
	part.CanCollide = if f.collide ~= nil then f.collide else not decor
	part.CanQuery = if f.query ~= nil then f.query else not decor
	part.CanTouch = not decor and part.CanCollide
	part.CastShadow = if f.shadow ~= nil then f.shadow else not decor
	part.Parent = parent
	countPart()
end

-- Generic block. Structural by default (collides, casts shadows).
function Builder.CreatePart(
	parent: Instance?,
	name: string,
	size: Vector3,
	cf: CFrame,
	swatch: Swatch,
	flags: PartFlags?
): Part
	local part = Instance.new("Part")
	setup(part, parent, name, size, cf, swatch, flags)
	return part
end

-- Alias with the vocabulary the rest of MapGen uses for solid boxes.
Builder.CreateBox = Builder.CreatePart

-- Small decorative block (no collision / query / touch / shadow).
function Builder.CreateDecor(
	parent: Instance?,
	name: string,
	size: Vector3,
	cf: CFrame,
	swatch: Swatch,
	flags: PartFlags?
): Part
	local f = flags or NO_FLAGS
	local merged: PartFlags = {
		decor = true,
		collide = f.collide,
		shadow = f.shadow,
		query = f.query,
		transparency = f.transparency,
		reflectance = f.reflectance,
		color = f.color,
		material = f.material,
	}
	return Builder.CreatePart(parent, name, size, cf, swatch, merged)
end

-- A Seat (players can sit on it). Anchored, collidable, touchable, enabled.
function Builder.CreateSeat(parent: Instance?, name: string, size: Vector3, cf: CFrame, swatch: Swatch): Seat
	local seat = Instance.new("Seat")
	seat.Disabled = false
	setup(seat, parent, name, size, cf, swatch, nil)
	seat.CanTouch = true
	return seat
end

-- A SpawnLocation (no force field, any team).
function Builder.CreateSpawn(parent: Instance?, name: string, size: Vector3, cf: CFrame, swatch: Swatch): SpawnLocation
	local spawnLocation = Instance.new("SpawnLocation")
	spawnLocation.Neutral = true
	spawnLocation.Duration = 0
	spawnLocation.Enabled = true
	spawnLocation.AllowTeamChangeOnTouch = false
	setup(spawnLocation, parent, name, size, cf, swatch, nil)
	return spawnLocation
end

-- WedgePart: the slope runs from the bottom-front (-Z) edge up to the
-- top-back (+Z) edge; the tall vertical face is at +Z.
function Builder.CreateWedge(
	parent: Instance?,
	name: string,
	size: Vector3,
	cf: CFrame,
	swatch: Swatch,
	flags: PartFlags?
): WedgePart
	local wedge = Instance.new("WedgePart")
	setup(wedge, parent, name, size, cf, swatch, flags)
	return wedge
end

function Builder.CreateCornerWedge(
	parent: Instance?,
	name: string,
	size: Vector3,
	cf: CFrame,
	swatch: Swatch,
	flags: PartFlags?
): CornerWedgePart
	local wedge = Instance.new("CornerWedgePart")
	setup(wedge, parent, name, size, cf, swatch, flags)
	return wedge
end

-- TrussPart (climbable by players: only use where nobody can reach it).
function Builder.CreateTruss(parent: Instance?, name: string, length: number, cf: CFrame, swatch: Swatch): TrussPart
	local truss = Instance.new("TrussPart")
	truss.Style = Enum.Style.AlternatingSupports
	setup(truss, parent, name, Vector3.new(2, length, 2), cf, swatch, { shadow = false })
	return truss
end

-- Cylinder whose axis is the local X axis of `cf`.
function Builder.CreateCylinder(
	parent: Instance?,
	name: string,
	length: number,
	diameter: number,
	cf: CFrame,
	swatch: Swatch,
	flags: PartFlags?
): Part
	local part = Instance.new("Part")
	part.Shape = Enum.PartType.Cylinder
	setup(part, parent, name, Vector3.new(length, diameter, diameter), cf, swatch, flags)
	return part
end

-- Vertical cylinder standing on `base` (a point at the bottom centre).
function Builder.CreatePost(
	parent: Instance?,
	name: string,
	base: Vector3,
	height: number,
	diameter: number,
	swatch: Swatch,
	flags: PartFlags?
): Part
	local cf = CFrame.new(base + Vector3.new(0, height / 2, 0)) * Builder.AxisY
	return Builder.CreateCylinder(parent, name, height, diameter, cf, swatch, flags)
end

-- A frame whose X axis points along `direction` (any direction, including
-- straight up/down where CFrame.lookAt would be degenerate).
function Builder.alongX(position: Vector3, direction: Vector3): CFrame
	local x = direction.Unit
	local helper = if math.abs(x.Y) < 0.95 then Vector3.yAxis else Vector3.xAxis
	local z = x:Cross(helper).Unit
	local y = z:Cross(x)
	return CFrame.fromMatrix(position, x, y, z)
end

-- A frame at `position` whose LookVector is `direction` (safe for vertical).
function Builder.facing(position: Vector3, direction: Vector3): CFrame
	local look = direction.Unit
	local up = if math.abs(look.Y) < 0.95 then Vector3.yAxis else Vector3.zAxis
	return CFrame.lookAt(position, position + look, up)
end

-- Cylinder spanning from point `a` to point `b`.
function Builder.CreateCylinderBetween(
	parent: Instance?,
	name: string,
	a: Vector3,
	b: Vector3,
	diameter: number,
	swatch: Swatch,
	flags: PartFlags?
): Part
	local delta = b - a
	return Builder.CreateCylinder(parent, name, delta.Magnitude, diameter, Builder.alongX((a + b) / 2, delta), swatch, flags)
end

function Builder.CreateBall(
	parent: Instance?,
	name: string,
	diameter: number,
	cf: CFrame,
	swatch: Swatch,
	flags: PartFlags?
): Part
	local part = Instance.new("Part")
	part.Shape = Enum.PartType.Ball
	setup(part, parent, name, Vector3.new(diameter, diameter, diameter), cf, swatch, flags)
	return part
end

-- Neon emitter. Decorative (non-colliding) unless flags say otherwise.
function Builder.CreateNeon(
	parent: Instance?,
	name: string,
	size: Vector3,
	cf: CFrame,
	color: Color3,
	flags: PartFlags?
): Part
	local neon: Swatch = { Color = color, Material = Enum.Material.Neon }
	local f: PartFlags = flags or { decor = true }
	return Builder.CreatePart(parent, name, size, cf, neon, f)
end

-- Invisible, anchored, non-colliding, non-queryable marker part.
function Builder.CreateMarker(parent: Instance?, name: string, cf: CFrame, size: Vector3?): Part
	local marker = Builder.CreatePart(parent, name, size or Vector3.new(1, 1, 1), cf, Palette.Charcoal, {
		decor = true,
		transparency = 1,
	})
	return marker
end

----------------------------------------------------------------------------
-- Walls and floors
----------------------------------------------------------------------------

-- A slab whose TOP surface is at `top.Y`, centred on top.X / top.Z.
function Builder.CreateFloor(
	parent: Instance?,
	name: string,
	top: Vector3,
	sizeX: number,
	sizeZ: number,
	swatch: Swatch,
	thickness: number?
): Part
	local t = thickness or 1
	local cf = CFrame.new(top.X, top.Y - t / 2, top.Z)
	return Builder.CreatePart(parent, name, Vector3.new(sizeX, t, sizeZ), cf, swatch)
end

-- A straight wall from `from` to `to` (both at the wall's BASE, on its centre
-- line), `height` tall and `thickness` thick.
function Builder.CreateWall(
	parent: Instance?,
	name: string,
	from: Vector3,
	to: Vector3,
	height: number,
	thickness: number,
	swatch: Swatch,
	flags: PartFlags?
): Part
	local flat = Vector3.new(to.X - from.X, 0, to.Z - from.Z)
	local centre = Vector3.new((from.X + to.X) / 2, from.Y + height / 2, (from.Z + to.Z) / 2)
	local cf = CFrame.fromMatrix(centre, flat.Unit, Vector3.yAxis)
	return Builder.CreatePart(parent, name, Vector3.new(flat.Magnitude, height, thickness), cf, swatch, flags)
end

-- Removes every hole interval from [lo, hi]. Holes are {a, b} pairs in any
-- order and may overlap. Returns the remaining pieces, sorted.
function Builder.SubtractIntervals(lo: number, hi: number, holes: { { number } }): { { number } }
	local sorted = table.clone(holes)
	table.sort(sorted, function(a, b)
		return a[1] < b[1]
	end)
	local pieces: { { number } } = {}
	local cursor = lo
	for _, hole in sorted do
		local a, b = math.max(hole[1], lo), math.min(hole[2], hi)
		if b > a then
			if a - cursor > 1e-3 then
				table.insert(pieces, { cursor, a })
			end
			cursor = math.max(cursor, b)
		end
	end
	if hi - cursor > 1e-3 then
		table.insert(pieces, { cursor, hi })
	end
	return pieces
end

-- A wall with rectangular openings (doorways, windows, the two-way mirror).
-- `frame` sits on the wall's centre line at its BASE: local X runs along the
-- wall (length centred on the frame), local Y up, local Z through the
-- thickness. The wall is cut into vertical columns at every opening edge; each
-- column keeps whatever is not covered by an opening, so the result is the
-- minimum number of solid blocks.
function Builder.CreateWallWithOpenings(
	parent: Instance?,
	name: string,
	frame: CFrame,
	length: number,
	height: number,
	thickness: number,
	swatch: Swatch,
	openings: { Opening },
	flags: PartFlags?
): { Part }
	local half = length / 2
	local edges = { -half, half }
	for _, opening in openings do
		table.insert(edges, math.clamp(opening.center - opening.width / 2, -half, half))
		table.insert(edges, math.clamp(opening.center + opening.width / 2, -half, half))
	end
	table.sort(edges)

	local parts: { Part } = {}
	for index = 1, #edges - 1 do
		local a, b = edges[index], edges[index + 1]
		if b - a > 1e-3 then
			local mid = (a + b) / 2
			local holes: { { number } } = {}
			for _, opening in openings do
				if math.abs(mid - opening.center) < opening.width / 2 then
					table.insert(holes, { opening.bottom, opening.top })
				end
			end
			for _, span in Builder.SubtractIntervals(0, height, holes) do
				local lo, hi = span[1], span[2]
				local cf = frame * CFrame.new(mid, (lo + hi) / 2, 0)
				local piece = Builder.CreatePart(parent, name, Vector3.new(b - a, hi - lo, thickness), cf, swatch, flags)
				table.insert(parts, piece)
			end
		end
	end
	return parts
end

-- Grows every gap interval by `amount` on both sides. Stacked trims use
-- slightly different gap edges so their end faces never share a plane.
function Builder.WidenIntervals(intervals: { { number } }, amount: number): { { number } }
	local out: { { number } } = {}
	for _, interval in intervals do
		table.insert(out, { interval[1] - amount, interval[2] + amount })
	end
	return out
end

-- Repeats a trim strip along a wall face, skipping `gaps` (intervals along
-- the face frame's local X). `face` is a frame ON the wall surface at floor
-- height whose LookVector points away from the wall (into the room). The
-- strip spans [y0, y1] vertically and sticks out from `depth0` to `depth1`.
function Builder.CreateTrimRun(
	parent: Instance?,
	name: string,
	face: CFrame,
	from: number,
	to: number,
	y0: number,
	y1: number,
	depth0: number,
	depth1: number,
	swatch: Swatch,
	gaps: { { number } }?,
	flags: PartFlags?
): { Part }
	local parts: { Part } = {}
	local f: PartFlags = flags or { decor = true }
	for _, span in Builder.SubtractIntervals(from, to, gaps or {}) do
		local a, b = span[1], span[2]
		local size = Vector3.new(b - a, y1 - y0, depth1 - depth0)
		local cf = face * CFrame.new((a + b) / 2, (y0 + y1) / 2, -(depth0 + depth1) / 2)
		table.insert(parts, Builder.CreatePart(parent, name, size, cf, swatch, f))
	end
	return parts
end

----------------------------------------------------------------------------
-- Text
----------------------------------------------------------------------------

-- SurfaceGui + a single full-size TextLabel on one face of `part`.
function Builder.CreateSurfaceText(part: BasePart, face: Enum.NormalId, text: string, options: TextOptions?): TextLabel
	local o: TextOptions = options or {}
	local gui = Instance.new("SurfaceGui")
	gui.Name = o.guiName or "SurfaceText"
	gui.Face = face
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = o.pixelsPerStud or 40
	gui.LightInfluence = o.lightInfluence or 0.4
	gui.Brightness = o.brightness or 1
	gui.ClipsDescendants = true
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

	local padding = o.padding or 0.05
	local label = Instance.new("TextLabel")
	label.Name = o.name or "Text"
	label.AnchorPoint = Vector2.new(0.5, 0.5)
	label.Position = UDim2.fromScale(0.5, 0.5)
	label.Size = UDim2.fromScale(1 - padding * 2, 1 - padding * 2)
	label.BackgroundTransparency = 1
	label.BorderSizePixel = 0
	label.FontFace = Font.fromEnum(o.font or Palette.Font.Sign)
	label.Text = text
	label.TextScaled = true
	label.TextWrapped = true
	label.TextColor3 = o.color or Palette.Text.Cream
	label.TextStrokeColor3 = o.strokeColor or Color3.new(0, 0, 0)
	label.TextStrokeTransparency = o.strokeTransparency or 1
	label.TextXAlignment = o.xAlignment or Enum.TextXAlignment.Center
	label.Parent = gui

	if o.background then
		local backdrop = Instance.new("Frame")
		backdrop.Name = "Background"
		backdrop.Size = UDim2.fromScale(1, 1)
		backdrop.BackgroundColor3 = o.background
		backdrop.BackgroundTransparency = o.backgroundTransparency or 0
		backdrop.BorderSizePixel = 0
		backdrop.ZIndex = 0
		backdrop.Parent = gui
	end

	gui.Parent = part
	return label
end

-- Yellow / black diagonal hazard stripes painted on one face of `part`.
function Builder.AddHazardStripes(part: BasePart, face: Enum.NormalId, stripes: number?)
	local gui = Instance.new("SurfaceGui")
	gui.Name = "HazardStripes"
	gui.Face = face
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 20
	gui.LightInfluence = 1
	gui.ClipsDescendants = true

	local count = stripes or 8
	for index = 0, count do
		local stripe = Instance.new("Frame")
		stripe.Name = "Stripe"
		stripe.AnchorPoint = Vector2.new(0.5, 0.5)
		stripe.Position = UDim2.fromScale((index + 0.5) / (count + 1), 0.5)
		stripe.Size = UDim2.new(0.5 / (count + 1), 0, 3, 0)
		stripe.Rotation = 35
		stripe.BackgroundColor3 = Palette.Rubber.Color
		stripe.BorderSizePixel = 0
		stripe.Parent = gui
	end
	gui.Parent = part
end

----------------------------------------------------------------------------
-- Lights
----------------------------------------------------------------------------
local function applyLight(light: Light, options: LightOptions)
	light.Color = options.color
	light.Brightness = options.brightness
	light.Shadows = options.shadows == true
	light.Enabled = options.enabled ~= false
end

function Builder.AddPointLight(part: BasePart, options: LightOptions): PointLight
	local light = Instance.new("PointLight")
	light.Name = options.name or "PointLight"
	applyLight(light, options)
	light.Range = options.range
	light.Parent = part
	return light
end

function Builder.AddSpotLight(part: BasePart, options: LightOptions): SpotLight
	local light = Instance.new("SpotLight")
	light.Name = options.name or "SpotLight"
	applyLight(light, options)
	light.Range = options.range
	light.Angle = options.angle or 90
	light.Face = options.face or Enum.NormalId.Bottom
	light.Parent = part
	return light
end

function Builder.AddSurfaceLight(part: BasePart, options: LightOptions): SurfaceLight
	local light = Instance.new("SurfaceLight")
	light.Name = options.name or "SurfaceLight"
	applyLight(light, options)
	light.Range = options.range
	light.Angle = options.angle or 90
	light.Face = options.face or Enum.NormalId.Bottom
	light.Parent = part
	return light
end

return Builder
