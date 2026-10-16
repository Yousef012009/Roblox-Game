--!strict
--[[
	Lobby  (ModuleScript)  ·  ServerScriptService/MapGen/Lobby

	The Metropolitan Detective Bureau lobby: a 140 × 120 stud hall centred on
	the origin, ceiling at Y = 34, floor top at Y = 0.2.

	        Z = -60  back wall: 4 elevator doorways (QueueElevator), mezzanine
	                 balcony at Y 15, "METROPOLITAN DETECTIVE BUREAU" sign
	   X = -70 ┌──────────────────────────────────────────┐ X = +70
	           │  shelves        pillars        shelves   │  side walls: three
	  windows  │  waiting area   RECEPTION   waiting area │  recessed window bays
	  + rain   │  cabinets      (CRT wall)     cabinets   │  each, rain outside,
	           │                 SPAWN (Z 40)             │  alley + building
	           └──────────────────────────────────────────┘  across the alley
	        Z = +60  front wall: sealed entrance doors, EXIT sign, clock

	Everything is enclosed: walls run from below the floor to the ceiling
	slab, the windows are collidable glass and the alley behind them is a
	closed box, so nobody can fall or climb out.

	Wall "faces" below are CFrames on the interior surface of a wall at floor
	height whose LookVector points into the room; trims and wall props are
	placed with face * CFrame.new(u, height, -depth).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Builder = require(script.Parent.Builder)
local Palette = require(script.Parent.Palette)
local Props = require(script.Parent.Props)
local QueueElevator = require(script.Parent.QueueElevator)
local Names = require(ReplicatedStorage.Shared.Names)

type Swatch = Palette.Swatch
type PartFlags = Builder.PartFlags

local P = Palette
local V = Vector3.new
local C = CFrame.new
local box = Builder.CreateBox
local decor = Builder.CreateDecor
local DECOR: PartFlags = table.freeze({ decor = true })
local NO_SHADOW: PartFlags = table.freeze({ shadow = false })

local Q = QueueElevator.Layout

local FLOOR = Q.FloorTop -- 0.2
local CEILING = 34
local HALF_X, HALF_Z = 70, 60
local SIDE_WALL_T = 3
local FRONT_WALL_T = 2
local WALL_BASE = -0.8 -- walls start below the floor so no seam ever shows
local WALL_HEIGHT = CEILING + 1 - WALL_BASE -- up to the top of the ceiling slab

local WINDOW_Z = { -29, 0, 29 }
local WINDOW_WIDTH = 12
local WINDOW_BOTTOM, WINDOW_TOP = 8, 24
local PILASTER_Z = { -44, -14.5, 14.5, 44 }
local PILLARS = { V(-30, 0, -30), V(30, 0, -30), V(-30, 0, 0), V(30, 0, 0), V(-30, 0, 30), V(30, 0, 30) }
local BEAMS_Z = { -30, 0, 30 }
local BEAMS_X = { -30, 30 }

local BALCONY_EDGE_Z = -53 -- front edge of the mezzanine deck
local BALCONY_TOP = 15 -- deck surface
local SPAWN_Z = 40

local Lobby = {}

type Context = {
	lobby: Model,
	structure: Folder,
	trim: Folder,
	furniture: Folder,
	decor: Folder,
	lamps: Folder,
	exterior: Folder,
	crts: Folder,
	fluorescents: Folder,
	rain: Folder,
	returns: Folder,
}

type Face = { frame: CFrame, half: number }

local function faceFrame(point: Vector3): CFrame
	return CFrame.lookAt(point, V(0, point.Y, 0))
end

-- u (the frame's local X) per face: back = -X, front = +X, west = +Z, east = -Z.
local FACES = table.freeze({
	back = { frame = faceFrame(V(0, FLOOR, -HALF_Z)), half = HALF_X } :: Face,
	front = { frame = faceFrame(V(0, FLOOR, HALF_Z)), half = HALF_X } :: Face,
	west = { frame = faceFrame(V(-HALF_X, FLOOR, 0)), half = HALF_Z } :: Face,
	east = { frame = faceFrame(V(HALF_X, FLOOR, 0)), half = HALF_Z } :: Face,
})

local function sideFace(side: number): Face
	return if side < 0 then FACES.west else FACES.east
end

-- A frame standing on the floor at (x, z) facing `target` (horizontal).
local function standing(x: number, z: number, targetX: number, targetZ: number): CFrame
	return CFrame.lookAt(V(x, FLOOR, z), V(targetX, FLOOR, targetZ))
end

----------------------------------------------------------------------------
-- Shell: floor, walls, ceiling
----------------------------------------------------------------------------
local function buildShell(ctx: Context)
	local s = ctx.structure
	Builder.CreateFloor(s, "Floor", V(0, FLOOR, 0), HALF_X * 2, HALF_Z * 2, P.ConcreteFloor)

	-- Back wall with the four elevator doorways.
	local doorways: { Builder.Opening } = {}
	for _, x in Q.CentersX do
		table.insert(doorways, { center = x, width = Q.DoorWidth, bottom = 0, top = FLOOR + Q.DoorHeight - WALL_BASE })
	end
	local backFrame = C(0, WALL_BASE, Q.WallZ - Q.WallThickness / 2)
	Builder.CreateWallWithOpenings(s, "BackWall", backFrame, HALF_X * 2, WALL_HEIGHT, Q.WallThickness, P.ConcreteBeige, doorways)

	box(s, "FrontWall", V(HALF_X * 2, WALL_HEIGHT, FRONT_WALL_T), C(0, WALL_BASE + WALL_HEIGHT / 2, HALF_Z + FRONT_WALL_T / 2), P.ConcreteBeige)

	-- Side walls with window bays. The wall frame is turned 90° so its local
	-- X runs along world -Z (hence the negated window centres).
	for _, side in { -1, 1 } do
		local frame = C(side * (HALF_X + SIDE_WALL_T / 2), WALL_BASE, 0) * CFrame.Angles(0, math.rad(90), 0)
		local windows: { Builder.Opening } = {}
		for _, z in WINDOW_Z do
			table.insert(windows, {
				center = -z,
				width = WINDOW_WIDTH,
				bottom = WINDOW_BOTTOM - WALL_BASE,
				top = WINDOW_TOP - WALL_BASE,
			})
		end
		Builder.CreateWallWithOpenings(s, "SideWall", frame, (HALF_Z + 2) * 2, WALL_HEIGHT, SIDE_WALL_T, P.ConcreteBeige, windows)
	end

	-- The slab ends just inside the walls' outer faces so no outer faces coincide.
	box(s, "Ceiling", V((HALF_X + SIDE_WALL_T - 0.1) * 2, 1, (HALF_Z + 2) * 2 - 0.2), C(0, CEILING + 0.5, 0), P.Ceiling)

	-- Coffered ceiling: deep primary beams along X over the pillar rows,
	-- shallower secondary beams along Z, and a stepped soffit round the edge.
	for _, z in BEAMS_Z do
		box(s, "Beam", V(HALF_X * 2, 3, 3), C(0, CEILING - 1.5, z), P.ConcreteDark)
	end
	for _, x in BEAMS_X do
		box(s, "Beam", V(2.6, 2.6, HALF_Z * 2), C(x, CEILING - 1.3, 0), P.ConcreteDark)
	end
	for _, side in { -1, 1 } do
		box(s, "Soffit", V(8, 4, 113), C(side * (HALF_X - 4), CEILING - 2, 3.5), P.Ceiling)
	end
	box(s, "Soffit", V((HALF_X - 8) * 2, 4, 6), C(0, CEILING - 2, HALF_Z - 3), P.Ceiling)

	-- Dark border band round the floor edge (doorway thresholds sit on top).
	box(s, "FloorBorder", V(HALF_X * 2, 0.02, 2.5), C(0, FLOOR + 0.01, -HALF_Z + 1.25), P.Charcoal, DECOR)
	box(s, "FloorBorder", V(HALF_X * 2, 0.02, 2.5), C(0, FLOOR + 0.01, HALF_Z - 1.25), P.Charcoal, DECOR)
	for _, side in { -1, 1 } do
		box(s, "FloorBorder", V(2.5, 0.02, HALF_Z * 2 - 5), C(side * (HALF_X - 1.25), FLOOR + 0.01, 0), P.Charcoal, DECOR)
	end
end

----------------------------------------------------------------------------
-- Wall trims, pilasters, pillars
----------------------------------------------------------------------------
local function buildTrim(ctx: Context)
	local t = ctx.trim
	local doorGaps: { { number } } = {}
	for _, x in Q.CentersX do
		-- back face u = -X
		table.insert(doorGaps, { -x - Q.FrameHalfWidth - 0.05, -x + Q.FrameHalfWidth + 0.05 })
	end
	-- Back/front runs span the full width; side runs stop just clear of each
	-- back/front trim's depth, so corners close without overlapping volumes,
	-- and the three trims of one run never share an end face.
	local runs = {
		{ face = FACES.back, gaps = doorGaps, corner = false },
		{ face = FACES.front, gaps = { { -7, 7 } }, corner = false },
		{ face = FACES.west, gaps = {}, corner = true },
		{ face = FACES.east, gaps = {}, corner = true },
	}
	local trims = {
		{ name = "Wainscot", y0 = 0, y1 = 4.2, depth = 0.12, swatch = P.FadedGreen, widen = 0.03 },
		{ name = "Baseboard", y0 = 0, y1 = 0.7, depth = 0.22, swatch = P.CharcoalDeep, widen = 0 },
		{ name = "ChairRail", y0 = 4.1, y1 = 4.5, depth = 0.28, swatch = P.WoodDark, widen = 0 },
	}
	for _, run in runs do
		for _, trim in trims do
			local inset = if run.corner then trim.depth + 0.01 else 0
			local gaps = Builder.WidenIntervals(run.gaps, trim.widen)
			local half = run.face.half
			Builder.CreateTrimRun(t, trim.name, run.face.frame, -half + inset, half - inset, trim.y0, trim.y1, 0.02, trim.depth, trim.swatch, gaps)
		end
	end

	-- Horizontal architectural lines (heights relative to the floor top).
	local headLow, headHigh = WINDOW_TOP - FLOOR + 0.5, WINDOW_TOP - FLOOR + 0.9
	for _, face in { FACES.west, FACES.east } do
		Builder.CreateTrimRun(t, "SillBand", face.frame, -face.half + 0.3, face.half - 0.3, WINDOW_BOTTOM - FLOOR - 0.4, WINDOW_BOTTOM - FLOOR, 0.02, 0.18, P.ConcreteDark)
		Builder.CreateTrimRun(t, "HeadBand", face.frame, -face.half + 0.3, face.half - 0.3, headLow, headHigh, 0.02, 0.18, P.ConcreteDark)
	end
	Builder.CreateTrimRun(t, "HeadBand", FACES.front.frame, -HALF_X, HALF_X, headLow, headHigh, 0.02, 0.18, P.ConcreteDark)
	Builder.CreateTrimRun(t, "Cornice", FACES.back.frame, -HALF_X, HALF_X, CEILING - FLOOR - 4.4, CEILING - FLOOR - 4.0, 0.02, 0.3, P.ConcreteDark)
	Builder.CreateTrimRun(t, "Crown", FACES.back.frame, -HALF_X, HALF_X, CEILING - FLOOR - 0.6, CEILING - FLOOR, 0.02, 0.45, P.ConcreteDark)
end

local function buildPillars(ctx: Context)
	local s, t = ctx.structure, ctx.trim
	-- Engaged pilasters between the window bays.
	for _, side in { -1, 1 } do
		for _, z in PILASTER_Z do
			box(s, "Pilaster", V(1.5, CEILING - FLOOR, 4), C(side * (HALF_X - 0.75), FLOOR + (CEILING - FLOOR) / 2, z), P.ConcreteLight)
			box(s, "PilasterBase", V(2.1, 1.4, 4.6), C(side * (HALF_X - 1.05), FLOOR + 0.7, z), P.ConcreteDark)
		end
	end
	-- Massive free-standing pillars under the primary beams.
	for _, p in PILLARS do
		box(s, "Pillar", V(4.5, 30.8, 4.5), C(p.X, FLOOR + 15.4, p.Z), P.ConcreteLight)
		box(s, "PillarBase", V(5.6, 1.4, 5.6), C(p.X, FLOOR + 0.7, p.Z), P.ConcreteDark)
		decor(t, "PillarBand", V(4.7, 2.8, 4.7), C(p.X, FLOOR + 2.8, p.Z), P.FadedGreen)
		decor(t, "PillarRail", V(4.86, 0.4, 4.86), C(p.X, FLOOR + 4.4, p.Z), P.WoodDark)
		box(s, "PillarCap", V(5.6, 1.6, 5.6), C(p.X, CEILING - 3.85, p.Z), P.ConcreteDark)
	end
end

----------------------------------------------------------------------------
-- Mezzanine balcony along the back wall
----------------------------------------------------------------------------
local function buildBalcony(ctx: Context)
	local s, t, f = ctx.structure, ctx.trim, ctx.furniture
	local depth = BALCONY_EDGE_Z - Q.WallZ
	box(s, "BalconyDeck", V(HALF_X * 2, 1, depth), C(0, BALCONY_TOP - 0.5, (Q.WallZ + BALCONY_EDGE_Z) / 2), P.ConcreteDark)
	box(s, "BalconyFascia", V(HALF_X * 2, 1.8, 0.4), C(0, BALCONY_TOP - 0.5, BALCONY_EDGE_Z + 0.2), P.WoodDark)
	decor(t, "FasciaTrim", V(HALF_X * 2, 0.2, 0.06), C(0, BALCONY_TOP - 1.3, BALCONY_EDGE_Z + 0.43), P.Brass)

	local railZ = BALCONY_EDGE_Z - 0.3
	for index = 0, 19 do
		box(s, "RailPost", V(0.25, 3.4, 0.25), C(-66.5 + index * 7, BALCONY_TOP + 1.7, railZ), P.MetalDark, NO_SHADOW)
	end
	Builder.CreateCylinder(s, "Handrail", HALF_X * 2, 0.3, C(0, BALCONY_TOP + 3.5, railZ), P.WoodDark, NO_SHADOW)
	Builder.CreateCylinder(s, "MidRail", HALF_X * 2, 0.16, C(0, BALCONY_TOP + 1.8, railZ), P.MetalDark, NO_SHADOW)

	-- Steel columns between the elevator bays.
	local columnHeight = BALCONY_TOP - 1 - FLOOR
	local columnZ = BALCONY_EDGE_Z - 1.2
	for _, x in { -30, 0, 30 } do
		box(s, "BalconyColumn", V(1.6, columnHeight, 1.6), C(x, FLOOR + columnHeight / 2, columnZ), P.MetalDark)
		decor(t, "ColumnBase", V(2.2, 0.6, 2.2), C(x, FLOOR + 0.3, columnZ), P.MetalOxidised)
		decor(t, "ColumnCap", V(2.2, 0.5, 2.2), C(x, BALCONY_TOP - 1.25, columnZ), P.MetalOxidised)
	end

	-- Upper-floor offices glimpsed above the railing.
	for _, spec in { { x = -56, label = "HOMICIDE" }, { x = 56, label = "RECORDS" } } do
		local at = V(spec.x, BALCONY_TOP, Q.WallZ)
		Props.CreateDoor(CFrame.lookAt(at, at + Vector3.zAxis), f, { kind = "Office", width = 4, height = 8, label = spec.label })
	end
	for _, x in { -44, 44 } do
		Props.CreateFilingCabinet(CFrame.lookAt(V(x, BALCONY_TOP, -58.6), V(x, BALCONY_TOP, 0)), f)
	end
	Props.CreateCoatRack(C(-63, BALCONY_TOP, -57.5), f)
end

----------------------------------------------------------------------------
-- Windows, rain and the alley outside
----------------------------------------------------------------------------
local function addRain(part: BasePart)
	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = "Rain"
	emitter.EmissionDirection = Enum.NormalId.Bottom
	emitter.Shape = Enum.ParticleEmitterShape.Box
	emitter.ShapeStyle = Enum.ParticleEmitterShapeStyle.Volume
	emitter.Rate = 32
	emitter.Lifetime = NumberRange.new(0.42, 0.55)
	emitter.Speed = NumberRange.new(44, 52)
	emitter.SpreadAngle = Vector2.new(3, 3)
	emitter.Acceleration = V(0, -30, 0)
	-- Thin vertical streaks: aligned with velocity, squashed narrow and tall.
	emitter.Orientation = Enum.ParticleOrientation.VelocityParallel
	emitter.Size = NumberSequence.new(0.18)
	emitter.Squash = NumberSequence.new(3)
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.6),
		NumberSequenceKeypoint.new(0.2, 0.35),
		NumberSequenceKeypoint.new(1, 0.65),
	})
	emitter.Color = ColorSequence.new(Color3.fromRGB(168, 188, 206))
	emitter.LightEmission = 0.5
	emitter.LightInfluence = 0.3
	emitter.Brightness = 1.2
	emitter.Parent = part
end

local function buildExterior(ctx: Context, side: number)
	local e = ctx.exterior
	local outer = HALF_X + SIDE_WALL_T -- outer face of the side wall (73)
	local alleyWidth = 7
	local buildingFace = outer + alleyWidth -- 80
	local length = (HALF_Z + 3) * 2
	box(e, "AlleyFloor", V(alleyWidth, 1, length), C(side * (outer + alleyWidth / 2), FLOOR - 0.5, 0), P.Asphalt, NO_SHADOW)
	box(e, "OppositeBuilding", V(1, 47, length), C(side * (buildingFace + 0.5), 22.7, 0), P.Exterior, NO_SHADOW)
	box(e, "AlleyRoof", V(alleyWidth + 1, 1, length), C(side * (outer + (alleyWidth + 1) / 2), 46.7, 0), P.CharcoalDeep, NO_SHADOW)
	for _, z in { -(HALF_Z + 2.5), HALF_Z + 2.5 } do
		box(e, "AlleyCap", V(alleyWidth + 1, 47, 1), C(side * (outer + (alleyWidth + 1) / 2), 22.7, z), P.Exterior, NO_SHADOW)
	end

	-- A few lit apartment windows across the alley.
	local lit = {
		V(0, 12, -40),
		V(0, 30, -18),
		V(0, 18, -6),
		V(0, 26, 22),
		V(0, 15, 34),
		V(0, 21, -52),
	}
	for index, spot in lit do
		local color = if index % 3 == 0 then P.Neon.WindowCold else P.Neon.WindowWarm
		Builder.CreateNeon(e, "LitWindow", V(0.06, 2.4, 1.6), C(side * (buildingFace - 0.04), spot.Y, spot.Z * side), color)
	end

	-- Rusted fire escape bolted to the building opposite (out of reach).
	local escapeZ = 14 * side
	Builder.CreateTruss(e, "FireEscape", 40, C(side * (buildingFace - 1), FLOOR + 20, escapeZ), P.MetalRust)
	for _, y in { 10, 20, 30 } do
		box(e, "Landing", V(2.6, 0.25, 10), C(side * (buildingFace - 1.3), y, escapeZ), P.MetalRust, NO_SHADOW)
		decor(e, "LandingRail", V(0.12, 1.6, 10), C(side * (buildingFace - 2.55), y + 0.9, escapeZ), P.MetalRust)
	end
end

-- A faint camera-facing shaft of moonlight from a window pane to the floor.
local function addMoonShaft(glass: BasePart, floor: BasePart, side: number)
	local top = Instance.new("Attachment")
	top.Name = "MoonShaftTop"
	top.Position = V(0, 4, 0)
	top.Parent = glass
	local landing = Instance.new("Attachment")
	landing.Name = "MoonShaftFloor"
	landing.CFrame = floor.CFrame:ToObjectSpace(C(side * (HALF_X - 15), FLOOR + 0.05, glass.Position.Z))
	landing.Parent = floor
	local beam = Instance.new("Beam")
	beam.Name = "MoonShaft"
	beam.Attachment0 = top
	beam.Attachment1 = landing
	beam.FaceCamera = true
	beam.Segments = 1
	beam.Width0 = 9
	beam.Width1 = 13
	beam.Color = ColorSequence.new(P.Light.Moon)
	beam.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.82),
		NumberSequenceKeypoint.new(1, 1),
	})
	beam.LightEmission = 1
	beam.LightInfluence = 0
	beam.Parent = glass
end

local function buildWindows(ctx: Context)
	local s, t = ctx.structure, ctx.trim
	local floor = s:FindFirstChild("Floor")
	assert(floor and floor:IsA("BasePart"), "lobby floor must be built before the windows")
	local height = WINDOW_TOP - WINDOW_BOTTOM
	local midY = (WINDOW_BOTTOM + WINDOW_TOP) / 2
	for _, side in { -1, 1 } do
		local glassX = side * (HALF_X + SIDE_WALL_T - 0.5)
		local mullionX = side * (HALF_X + SIDE_WALL_T - 0.83)
		for index, z in WINDOW_Z do
			local glass = box(s, "WindowGlass", V(0.2, height, WINDOW_WIDTH), C(glassX, midY, z), P.GlassDark, {
				transparency = 0.45,
				reflectance = 0.12,
				shadow = false,
			})
			decor(t, "Mullion", V(0.25, height, 0.35), C(mullionX, midY, z), P.MetalDark)
			for _, y in { WINDOW_BOTTOM + height / 3, WINDOW_BOTTOM + 2 * height / 3 } do
				decor(t, "Transom", V(0.22, 0.35, WINDOW_WIDTH), C(mullionX, y, z), P.MetalDark)
			end
			box(s, "WindowSill", V(2.8, 0.3, WINDOW_WIDTH + 0.8), C(side * (HALF_X + 1.0), WINDOW_BOTTOM + 0.05, z), P.ConcreteDark)
			decor(t, "WindowHead", V(0.3, 0.5, WINDOW_WIDTH + 0.8), C(side * (HALF_X - 0.15), WINDOW_TOP + 0.25, z), P.ConcreteDark)
			if index == 2 then
				-- Cold moonlight spilling in through the middle bays.
				Builder.AddSurfaceLight(glass, {
					name = "Moonlight",
					color = P.Light.Moon,
					brightness = 0.6,
					range = 22,
					angle = 70,
					face = if side > 0 then Enum.NormalId.Left else Enum.NormalId.Right,
				})
				addMoonShaft(glass, floor, side)
			end
			local emitterPart = Builder.CreateMarker(ctx.rain, "RainEmitter", C(side * (HALF_X + SIDE_WALL_T + 3.5), WINDOW_TOP + 1.5, z), V(6, 0.2, WINDOW_WIDTH + 1))
			addRain(emitterPart)
		end
		buildExterior(ctx, side)
	end
end

----------------------------------------------------------------------------
-- Front wall: sealed entrance, EXIT sign, clock, benches
----------------------------------------------------------------------------
local function buildEntrance(ctx: Context)
	local d, f = ctx.decor, ctx.furniture
	local face = FACES.front.frame -- u = world X
	for _, side in { -1, 1 } do
		box(d, "EntranceDoor", V(4.9, 14.36, 0.5), face * C(side * 2.5, 7.2, -0.27), P.WoodDark)
		decor(d, "DoorGlass", V(2.6, 5, 0.06), face * C(side * 2.5, 9.6, -0.55), P.GlassWired, { reflectance = 0.2 })
		decor(d, "PushBar", V(3.6, 0.25, 0.25), face * C(side * 2.5, 4.4, -0.65), P.Brass)
		box(d, "EntranceJamb", V(1.2, 14.4, 0.9), face * C(side * 5.6, 7.2, -0.47), P.WoodDark)
	end
	box(d, "EntranceHead", V(12.4, 1.2, 0.9), face * C(0, 15.0, -0.47), P.WoodDark)
	decor(d, "TransomFrame", V(10.8, 3.6, 0.04), face * C(0, 17.4, -0.04), P.WoodDark)
	decor(d, "Transom", V(10, 3, 0.06), face * C(0, 17.4, -0.08), P.GlassWired, { reflectance = 0.3 })

	local exit = Props.CreateSign(face * C(0, 21.0, 0), d, {
		width = 4,
		height = 1.2,
		text = "EXIT",
		font = P.Font.Display,
		color = P.Neon.Exit,
		plate = P.CharcoalDeep,
		frame = P.MetalDark,
		brightness = 2.2,
		lightInfluence = 0,
		pixelsPerStud = 30,
		name = "ExitSign",
	})
	local plate = exit:FindFirstChild("Plate")
	if plate and plate:IsA("BasePart") then
		Builder.AddPointLight(plate, { name = "Glow", color = P.Light.ExitRed, brightness = 0.5, range = 9 })
	end

	Props.CreateWallClock(face * C(0, 27.0, 0), d, { diameter = 4, hour = 11, minute = 58 })
	decor(d, "Doormat", V(10, 0.04, 3), C(0, FLOOR + 0.04, HALF_Z - 2), P.FabricCharcoal)

	for _, side in { -1, 1 } do
		Props.CreateBench(standing(side * 20, HALF_Z - 2.4, side * 20, 0), f, { width = 7 })
		Props.CreateTrashBin(C(side * 25.5, FLOOR, HALF_Z - 1.6), f)
		Props.CreateNoticeBoard(face * C(side * 16, 7.8, 0), d, {
			width = 8,
			height = 5,
			seed = if side < 0 then 5 else 9,
			title = if side < 0 then "MOST WANTED" else "MISSING PERSONS",
		})
	end
	Props.CreateCoatRack(C(-9, FLOOR, HALF_Z - 2), f)
end

----------------------------------------------------------------------------
-- The bureau sign over the balcony
----------------------------------------------------------------------------
local function buildBureauSign(ctx: Context)
	local d = ctx.decor
	local face = FACES.back.frame
	Props.CreateSign(face * C(0, 24.6, 0), d, {
		width = 62,
		height = 6.4,
		depth = 0.6,
		text = "METROPOLITAN DETECTIVE BUREAU",
		subtext = "HOMICIDE  -  VICE  -  SPECIAL CASES",
		font = P.Font.Sign,
		color = P.Text.Brass,
		plate = P.CharcoalDeep,
		frame = P.Brass,
		pixelsPerStud = 20,
		brightness = 1.6,
		lightInfluence = 0.15,
		name = "BureauSign",
	})
	-- Gooseneck picture lights above the sign.
	for _, u in { -20, 0, 20 } do
		local wallPoint = face * V(u, 28.9, 0)
		local tip = face * V(u, 28.6, -1.6)
		Builder.CreateCylinderBetween(d, "Gooseneck", wallPoint, tip, 0.14, P.Brass, DECOR)
		decor(d, "GooseneckShade", V(2.2, 0.35, 0.7), face * C(u, 28.45, -1.75), P.Brass)
		Builder.CreateNeon(d, "GooseneckTube", V(1.9, 0.08, 0.4), face * C(u, 28.24, -1.75), P.Neon.Bulb)
	end
	local lightBar = Builder.CreateMarker(d, "SignLight", face * C(0, 28.2, -1.75), V(40, 0.2, 0.4))
	Builder.AddSurfaceLight(lightBar, {
		name = "Light",
		color = P.Light.Warm,
		brightness = 1.2,
		range = 10,
		angle = 80,
		face = Enum.NormalId.Bottom,
	})
end

----------------------------------------------------------------------------
-- Spawn area (front centre)
----------------------------------------------------------------------------
local RETURN_POINTS = {
	V(-9.5, 0, SPAWN_Z - 6),
	V(-5, 0, SPAWN_Z - 6),
	V(5, 0, SPAWN_Z - 6),
	V(9.5, 0, SPAWN_Z - 6),
	V(-9.5, 0, SPAWN_Z + 6),
	V(-5, 0, SPAWN_Z + 6),
	V(5, 0, SPAWN_Z + 6),
	V(9.5, 0, SPAWN_Z + 6),
	V(-9.5, 0, SPAWN_Z),
	V(9.5, 0, SPAWN_Z),
}

local function buildSpawnArea(ctx: Context)
	local d = ctx.decor
	decor(d, "SpawnBorder", V(26, 0.03, 18), C(0, FLOOR + 0.015, SPAWN_Z), P.Brass)
	decor(d, "SpawnCarpet", V(25, 0.03, 17), C(0, FLOOR + 0.025, SPAWN_Z), P.Carpet)
	decor(d, "SpawnRing", V(8.6, 0.06, 8.6), C(0, FLOOR + 0.03, SPAWN_Z), P.Brass)

	-- The SpawnLocation: a low dark plate with the bureau monogram.
	local pad = Builder.CreateSpawn(ctx.lobby, Names.LobbySpawn, V(8, 0.3, 8), C(0, FLOOR + 0.05, SPAWN_Z), P.CharcoalDeep)
	Builder.CreateSurfaceText(pad, Enum.NormalId.Top, "M.D.B.", {
		font = P.Font.Sign,
		color = P.Text.Brass,
		pixelsPerStud = 30,
		lightInfluence = 0.8,
		padding = 0.2,
	})

	-- Bollard lamps at the carpet corners.
	for _, x in { -12, 12 } do
		for _, z in { SPAWN_Z - 8, SPAWN_Z + 8 } do
			Builder.CreatePost(d, "Bollard", V(x, FLOOR, z), 2.8, 0.6, P.MetalDark)
			Builder.CreateBall(d, "BollardLamp", 0.7, C(x, FLOOR + 3.0, z), { Color = P.Neon.AmberDim, Material = Enum.Material.Neon }, DECOR)
		end
	end

	-- Where players land after a match: invisible pads around the spawn,
	-- lying on the floor (stand a character 3 studs above one), facing -Z.
	for index, point in RETURN_POINTS do
		Builder.CreateMarker(ctx.returns, `ReturnPoint{index}`, C(point.X, FLOOR + 0.12, point.Z), V(2, 0.2, 2))
	end

	Props.CreateLightFixture(C(0, CEILING, SPAWN_Z), ctx.lamps, {
		kind = "Industrial",
		drop = 18,
		light = true,
		brightness = 2.2,
		range = 40,
		angle = 95,
		name = "SpawnLamp",
	})
	-- Centre aisle runner from the spawn carpet to the reception desk.
	decor(d, "AisleRunner", V(8, 0.03, 20), C(0, FLOOR + 0.015, 18), P.CarpetDark)
	-- Floor seal in front of the elevators: three stacked brass/charcoal discs.
	Builder.CreateCylinder(d, "Seal", 0.03, 12, C(0, FLOOR + 0.015, -38) * Builder.AxisY, P.Brass, DECOR)
	Builder.CreateCylinder(d, "Seal", 0.04, 10.6, C(0, FLOOR + 0.02, -38) * Builder.AxisY, P.CharcoalDeep, DECOR)
	Builder.CreateCylinder(d, "Seal", 0.05, 3, C(0, FLOOR + 0.025, -38) * Builder.AxisY, P.Brass, DECOR)
end

----------------------------------------------------------------------------
-- Reception (centre): U-shaped desk facing the spawn, CRT wall behind
----------------------------------------------------------------------------
local TERMINAL_TEXT = "METRO P.D. CASE TERMINAL\n> LOGIN ********\n> OPEN CASE 64\n> 4 SUSPECTS\n> NO REPEATS. NO HESITATION._"

local function buildReception(ctx: Context)
	local f, d = ctx.furniture, ctx.decor
	-- Desk frame: local -Z faces the spawn (world +Z); local +X is world -X.
	local R = CFrame.lookAt(V(0, FLOOR, 2), V(0, FLOOR, 10))

	box(f, "Counter", V(20, 3.8, 1.4), R * C(0, 1.9, -2.8), P.WoodDark)
	decor(f, "CounterPanel", V(19.2, 2.6, 0.06), R * C(0, 1.7, -3.53), P.Wood)
	decor(f, "CounterKick", V(20, 0.5, 0.08), R * C(0, 0.25, -3.54), P.CharcoalDeep)
	box(f, "CounterTop", V(20.6, 0.2, 1.9), R * C(0, 3.9, -2.8), P.Wood)
	for _, side in { -1, 1 } do
		box(f, "Wing", V(1.4, 3.8, 6.4), R * C(side * 9.3, 1.9, 1.1), P.WoodDark)
		box(f, "WingTop", V(1.9, 0.2, 6.15), R * C(side * 9.3, 3.9, 1.225), P.Wood)
	end
	box(f, "WorkSurface", V(17, 0.2, 2.4), R * C(0, 2.9, -0.9), P.Wood)

	local plate = decor(f, "Nameplate", V(5, 0.8, 0.06), R * C(0, 2.9, -3.6), P.Brass)
	Builder.CreateSurfaceText(plate, Enum.NormalId.Front, "INFORMATION", {
		font = P.Font.Plaque,
		color = P.Text.Ink,
		pixelsPerStud = 40,
		lightInfluence = 1,
	})

	-- Receptionist's station.
	Props.CreateChair(R * C(0, 0, 2.2), f, { style = "Wood" })
	Props.CreateCRTMonitor(R * C(-3, 3.0, -1.0) * CFrame.Angles(0, math.pi, 0), f, {
		width = 1.8,
		kind = "Monitor",
		screenText = TERMINAL_TEXT,
		name = "Terminal",
	})
	decor(f, "Keyboard", V(1.8, 0.12, 0.6), R * C(-3, 3.06, 0.0), P.CaseBeige)
	Props.CreateTelephone(R * C(3.5, 3.0, -0.8), f)
	Props.CreatePaperStack(R * C(4.5, 4.0, -2.8), f, { seed = 4, sheets = 3, folder = true })
	Props.CreatePaperStack(R * C(-5.5, 4.0, -2.7), f, { seed = 8, sheets = 2 })
	Props.CreatePaperStack(R * C(6.0, 3.0, -0.6), f, { seed = 12, sheets = 4 })
	Props.CreatePaperStack(R * C(9.3, 4.0, 2.5), f, { seed = 15, sheets = 3, folder = true })
	Props.CreateDeskLamp(R * C(-7, 4.0, -2.6), ctx.lamps, { light = true, shadows = true })
	Builder.CreateBall(f, "ServiceBell", 0.4, R * C(0.8, 4.05, -3.0), P.Brass, DECOR)

	-- The CRT wall: six TVs of static on an industrial rack behind the desk.
	local _, shelfTops = Props.CreateShelf(R * C(0, 0, 8), f, { width = 12, height = 7.6, depth = 2.2, levels = 3, boxes = false })
	for row = 1, 2 do
		for column = -1, 1 do
			Props.CreateCRTMonitor(R * C(column * 3.7, shelfTops[row], 8), ctx.crts, { width = 2.4, kind = "TV" })
		end
	end
	for _, x in { -3.8, 0.4, 3.6 } do
		decor(f, "ArchiveBox", V(2.6, 1.2, 1.8), R * C(x, shelfTops[3] + 0.61, 8) * CFrame.Angles(0, math.rad(x * 2), 0), P.Cardboard)
	end
	for _, side in { -1, 1 } do
		Props.CreateFilingCabinet(R * C(side * 7.8, 0, 8), f)
	end

	-- Hanging RECEPTION sign and the lamp over the desk.
	local sign = Props.CreateSign(R * C(0, 15.8, -2.8), d, {
		width = 10,
		height = 1.6,
		depth = 0.2,
		text = "RECEPTION",
		font = P.Font.Sign,
		color = P.Text.Cream,
		plate = P.CharcoalDeep,
		frame = P.Brass,
		pixelsPerStud = 30,
		brightness = 1.3,
		twoSided = true,
		name = "ReceptionSign",
	})
	local pivot = sign:GetPivot()
	for _, u in { -4.5, 4.5 } do
		local top = pivot * V(u, 0.95, -0.1)
		Builder.CreateCylinderBetween(d, "SignCable", top, V(top.X, CEILING, top.Z), 0.06, P.MetalDark, DECOR)
	end
	Props.CreateLightFixture(C(0, CEILING, 3), ctx.lamps, {
		kind = "Industrial",
		drop = 20,
		light = true,
		brightness = 2,
		range = 34,
		angle = 100,
		name = "ReceptionLamp",
	})
end

----------------------------------------------------------------------------
-- Waiting areas (one each side), facing the side walls
----------------------------------------------------------------------------
local function buildWaitingArea(ctx: Context, side: number)
	local f = ctx.furniture
	-- Local -Z points at the nearest side wall.
	local W = C(side * 47, FLOOR, 16) * CFrame.Angles(0, -side * math.rad(90), 0)

	decor(f, "RugBorder", V(15, 0.03, 13), W * C(0, 0.015, 0), P.CarpetDark)
	decor(f, "Rug", V(14, 0.03, 12), W * C(0, 0.025, 0), if side < 0 then P.FabricGreen else P.Carpet)

	Props.CreateCouch(W * C(0, 0, 4.2), f, { seats = 3, swatch = P.Leather })
	Props.CreateArmchair(W * C(-5.8, 0, -0.5) * CFrame.Angles(0, math.rad(-90), 0), f, P.FabricGreen)
	Props.CreateArmchair(W * C(5.8, 0, -0.5) * CFrame.Angles(0, math.rad(90), 0), f, P.FabricGreen)
	Props.CreateCoffeeTable(W * C(0, 0, 0.3), f, { width = 4, depth = 2.4 })

	-- Old TV on a rolling cart, facing the couch.
	local facingCouch = CFrame.Angles(0, math.pi, 0)
	Props.CreateTVStand(W * C(0, 0, -5.5) * facingCouch, f, { width = 3.2, height = 2.6 })
	Props.CreateCRTMonitor(W * C(0, 2.675, -5.5) * facingCouch, ctx.crts, { width = 2.6, kind = "TV", antenna = true })

	Props.CreatePlant(W * C(-5.8, 0, 4.6), f, if side < 0 then 21 else 22)
	Props.CreateTrashBin(W * C(-3.4, 0, -5.6), f)
	-- Ashtray stand by the right armchair.
	Builder.CreatePost(f, "AshtrayStand", (W * C(5.8, 0, 2.6)).Position, 2.6, 0.3, P.MetalDark, DECOR)
	Builder.CreatePost(f, "Ashtray", (W * C(5.8, 2.6, 2.6)).Position, 0.15, 0.9, P.MetalDark, DECOR)
end

----------------------------------------------------------------------------
-- Storage along the side walls
----------------------------------------------------------------------------
local function buildStorage(ctx: Context)
	local f = ctx.furniture
	for _, side in { -1, 1 } do
		local wall = side * HALF_X
		for index, z in { -50, -38.5 } do
			local x = wall - side * 1.2
			Props.CreateShelf(standing(x, z, 0, z), f, { width = 6, height = 8, depth = 2, levels = 4, seed = index * 10 + side })
		end
		for _, z in { 35.5, 37.5, 39.5 } do
			local x = wall - side * 1.4
			Props.CreateFilingCabinet(standing(x, z, 0, z), f)
		end
	end
	Props.CreateWaterCooler(standing(-60, 2, 0, 2), f)
	Props.CreateWaterCooler(standing(60, 30, 0, 30), f)
end

-- Duty desks in the two front corners: the officer sits on the wall side
-- (the desk's -Z) and faces the hall across the desk.
local DUTY_TEXT = "DUTY ROSTER\n> NIGHT SHIFT\n> 0 OFFICERS ON FLOOR\n> AWAIT ASSIGNMENT_"

local function buildDutyDesks(ctx: Context)
	local f = ctx.furniture
	for _, side in { -1, 1 } do
		local at = V(side * 52, FLOOR, 46)
		local desk = CFrame.lookAt(at, at + V(side, 0, 0))
		Props.CreateDesk(desk, f, { width = 6, depth = 3, height = 3 })
		Props.CreateChair(desk * C(0, 0, -2.6) * CFrame.Angles(0, math.pi, 0), f, { style = "Wood" })
		Props.CreateCRTMonitor(desk * C(-1.4, 3.0, 0.3), f, { width = 1.6, kind = "Monitor", screenText = DUTY_TEXT, name = "Terminal" })
		Props.CreateDeskLamp(desk * C(2.1, 3.0, 0.7), f)
		Props.CreatePaperStack(desk * C(0.9, 3.0, -0.3), f, { seed = if side < 0 then 41 else 42, sheets = 3, folder = true })
	end
end

----------------------------------------------------------------------------
-- Ceiling fixtures (the client flickers the fluorescents)
----------------------------------------------------------------------------
type FixtureSpot = { x: number, z: number, lit: boolean }

-- Fourteen hanging fluorescents; only six carry an actual light (budget).
local FLUORESCENTS: { FixtureSpot } = {
	{ x = -48, z = -40, lit = true },
	{ x = -16, z = -40, lit = true },
	{ x = 16, z = -40, lit = true },
	{ x = 48, z = -40, lit = true },
	{ x = -48, z = -14, lit = false },
	{ x = -16, z = -14, lit = false },
	{ x = 16, z = -14, lit = false },
	{ x = 48, z = -14, lit = false },
	{ x = -48, z = 12, lit = true },
	{ x = -16, z = 12, lit = false },
	{ x = 16, z = 12, lit = false },
	{ x = 48, z = 12, lit = true },
	{ x = -40, z = 44, lit = false },
	{ x = 40, z = 44, lit = false },
}

local function buildFixtures(ctx: Context)
	for index, spot in FLUORESCENTS do
		Props.CreateLightFixture(C(spot.x, CEILING, spot.z), ctx.fluorescents, {
			kind = "Fluorescent",
			drop = 12,
			light = spot.lit,
			brightness = 1.35,
			range = 40,
			angle = 115,
			name = `Fluorescent{index}`,
		})
	end
end

----------------------------------------------------------------------------
-- Wall details: clocks, vents, pipes, cameras, case boards
----------------------------------------------------------------------------
local function buildWallDetails(ctx: Context)
	local d = ctx.decor
	local back = FACES.back.frame

	for _, u in { -48, 48 } do
		Props.CreateWallClock(back * C(u, 24.8, 0), d, { diameter = 3, hour = if u < 0 then 3 else 11, minute = if u < 0 then 13 else 58 })
	end
	for index, u in { -60, 60 } do
		Props.CreateNoticeBoard(back * C(u, 7.0, 0), d, {
			width = 7,
			height = 4.5,
			seed = 30 + index,
			title = if index == 1 then "OPEN CASES" else "SHIFT ROSTER",
		})
	end

	for _, side in { -1, 1 } do
		local face = sideFace(side).frame
		for _, u in { -29, 29 } do
			Props.CreateVent(face * C(u, 27.3, 0), d, { width = 4, height = 1.6 })
		end
		-- Exposed steam main along the side wall, dropping to the floor by the front wall.
		local x = side * (HALF_X - 2.4)
		Props.CreatePipeRun(CFrame.identity, {
			V(x, 28.5, Q.WallZ + 0.1),
			V(x, 28.5, HALF_Z - 2.5),
			V(x, FLOOR, HALF_Z - 2.5),
		}, d, { diameter = 0.8, swatch = P.MetalOxidised, clampEvery = 20, collide = true })
		Builder.CreateCylinder(d, "ValveWheel", 0.12, 1.4, C(x - side * 0.5, 5, HALF_Z - 2.5), P.RedDesat, DECOR)
		Builder.CreateCylinder(d, "ValveStem", 0.5, 0.2, C(x - side * 0.25, 5, HALF_Z - 2.5), P.MetalDark, DECOR)

		-- CCTV over the spawn and over the elevator bank.
		Props.CreateSecurityCamera(CFrame.lookAt(V(side * HALF_X, 27, 50), V(0, 27, 50)), V(0, 3, SPAWN_Z - 6), d)
		Props.CreateSecurityCamera(CFrame.lookAt(V(side * HALF_X, 27, -48), V(0, 27, -48)), V(side * 30, 3, -56), d)
	end
	for _, u in { -30, 30 } do
		Props.CreateVent(FACES.front.frame * C(u, 1.6, 0), d, { width = 3, height = 1.2 })
	end
	-- Conduits along the back wall above the balcony.
	Props.CreatePipeRun(CFrame.identity, {
		V(-HALF_X + 0.1, 30.6, Q.WallZ + 0.5),
		V(HALF_X - 0.1, 30.6, Q.WallZ + 0.5),
	}, d, { diameter = 0.4, swatch = P.MetalDark, clampEvery = 24 })
end

----------------------------------------------------------------------------
-- Public
----------------------------------------------------------------------------

-- Builds Workspace.Map.Lobby (returned; parented to `parent` at the end so
-- the whole model replicates in one go).
function Lobby.CreateLobby(parent: Instance?): Model
	local lobby = Builder.newModel(Names.Lobby)
	local ctx: Context = {
		lobby = lobby,
		structure = Builder.newFolder("Structure", lobby),
		trim = Builder.newFolder("Trim", lobby),
		furniture = Builder.newFolder("Furniture", lobby),
		decor = Builder.newFolder("Decor", lobby),
		lamps = Builder.newFolder("Lamps", lobby),
		exterior = Builder.newFolder("Exterior", lobby),
		crts = Builder.newFolder(Names.CRTs, lobby),
		fluorescents = Builder.newFolder(Names.Fluorescents, lobby),
		rain = Builder.newFolder(Names.RainEmitters, lobby),
		returns = Builder.newFolder(Names.LobbyReturnPoints, lobby),
	}

	buildShell(ctx)
	buildTrim(ctx)
	buildPillars(ctx)
	buildBalcony(ctx)
	buildWindows(ctx)
	buildEntrance(ctx)
	buildBureauSign(ctx)
	buildSpawnArea(ctx)
	buildReception(ctx)
	buildWaitingArea(ctx, -1)
	buildWaitingArea(ctx, 1)
	buildStorage(ctx)
	buildDutyDesks(ctx)
	buildFixtures(ctx)
	buildWallDetails(ctx)

	lobby.Parent = parent
	return lobby
end

return Lobby
