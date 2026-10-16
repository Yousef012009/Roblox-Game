--!strict
--[[
	InterrogationModule  (ModuleScript)  ·  ServerScriptService/MapGen/InterrogationModule

	Builds ServerStorage.InterrogationModuleTemplate: one interrogation room
	plus the spectator lounge behind its two-way mirror. MatchService clones
	the template per match and pivots the clone to its slot.

	Module-local coordinates (the template's pivot = ModuleRoot = origin):

	        Z = -12 ┌──────── interrogation room ────────┬── lounge ──┐
	                │ TV on X = -14   [01]               │  desk/CRTs │
	                │            [04] TABLE [02]    mirror  ->  spawns │
	                │                 [03]     X = 14.5  │  railing   │
	        Z = +12 └──────────── door (X 6) ────────────┴────────────┘
	              X = -14                            X = 14  15      29

	  room interior    X ∈ [-14, 14], Z ∈ [-12, 12], Y ∈ [0.2, 14.2]
	  mirror opening   X = 14.5, Z ∈ [-9, 9], Y ∈ [3, 11] (glass, collidable)
	  lounge interior  X ∈ [15, 29], Z ∈ [-12, 12], Y ∈ [0.2, 12.2]
	  seats            01 N (0, -5.5) faces +Z · 02 E (7, 0) faces -X
	                   03 S (0, 5.5) faces -Z · 04 W (-7, 0) faces +X
	  bulb             BulbPivot (0, 13.6, 0); bulb 5.05 studs below it

	Room and lounge are sealed boxes; the only thing between them is the
	mirror glass, so nobody can walk from one to the other.
	Dynamic lights: BulbLight, TVGlow, Fill, AlarmLight (disabled), Lounge = 5.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Builder = require(script.Parent.Builder)
local Palette = require(script.Parent.Palette)
local Props = require(script.Parent.Props)
local Names = require(ReplicatedStorage.Shared.Names)
local Config = require(ReplicatedStorage.Shared.Config)

type Swatch = Palette.Swatch
type PartFlags = Builder.PartFlags

local P = Palette
local V = Vector3.new
local C = CFrame.new
local box = Builder.CreateBox
local decor = Builder.CreateDecor
local DECOR: PartFlags = table.freeze({ decor = true })

local FLOOR = 0.2
local ROOM_HALF_X, ROOM_HALF_Z = 14, 12
local ROOM_TOP = FLOOR + 14 -- 14.2
local MIRROR_X = 14.5
local MIRROR_HALF_Z = 9
local MIRROR_BOTTOM, MIRROR_TOP = 3, 11
local LOUNGE_MIN_X, LOUNGE_MAX_X = 15, 29
local LOUNGE_TOP = FLOOR + 12 -- 12.2
local TABLE_TOP = FLOOR + 3.2 -- 3.4
local BULB_PIVOT_Y = 13.6
local BULB_DROP = 5.05
local TV_WALL_X = -ROOM_HALF_X -- -14
local TV_CENTER_Y = 8
local DOOR_X = 6

local InterrogationModule = {}

-- Seat layout: clockwise from above starting north.
local SEATS = {
	V(0, 0, -5.5), -- 01 north
	V(7, 0, 0), -- 02 east
	V(0, 0, 5.5), -- 03 south
	V(-7, 0, 0), -- 04 west
}

local function faceFrame(point: Vector3, toward: Vector3): CFrame
	return CFrame.lookAt(point, V(toward.X, point.Y, toward.Z))
end

local function cameraAnchor(folder: Instance, name: string, position: Vector3, target: Vector3)
	Builder.CreateMarker(folder, name, CFrame.lookAt(position, target), V(1, 1, 1))
end

----------------------------------------------------------------------------
-- Room shell
----------------------------------------------------------------------------
local function buildRoomShell(module: Model)
	local s = Builder.getFolder(module, "RoomStructure")
	local wallHeight = ROOM_TOP + 1 + 0.8 -- from -0.8 to the top of the ceiling slab
	local wallMid = wallHeight / 2 - 0.8

	Builder.CreateFloor(s, "Floor", V((-ROOM_HALF_X - 1 + MIRROR_X) / 2, FLOOR, 0), MIRROR_X + ROOM_HALF_X + 1, ROOM_HALF_Z * 2 + 2, P.ConcreteStained)
	for _, side in { -1, 1 } do
		box(s, "Wall", V(ROOM_HALF_X * 2 + 2, wallHeight, 1), C(0, wallMid, side * (ROOM_HALF_Z + 0.5)), P.ConcreteBeige)
	end
	box(s, "Wall", V(1, wallHeight, ROOM_HALF_Z * 2), C(TV_WALL_X - 0.5, wallMid, 0), P.ConcreteBeige)

	-- Dividing wall with the mirror opening (frame's local X runs along -Z).
	local dividerFrame = C(MIRROR_X, -0.8, 0) * CFrame.Angles(0, math.rad(90), 0)
	Builder.CreateWallWithOpenings(s, "MirrorWall", dividerFrame, ROOM_HALF_Z * 2, wallHeight, 1, P.ConcreteBeige, {
		{ center = 0, width = MIRROR_HALF_Z * 2, bottom = MIRROR_BOTTOM + 0.8, top = MIRROR_TOP + 0.8 },
	})

	box(s, "Ceiling", V(ROOM_HALF_X * 2 + 2, 1, ROOM_HALF_Z * 2 + 2), C(0, ROOM_TOP + 0.5, 0), P.Ceiling)
	-- Exposed concrete beams and the steel I-beam the bulb hangs from.
	for _, x in { -7, 7 } do
		box(s, "Beam", V(1.2, 1, ROOM_HALF_Z * 2), C(x, ROOM_TOP - 0.5, 0), P.ConcreteDark)
	end
	decor(s, "IBeamWeb", V(ROOM_HALF_X * 2, 0.45, 0.25), C(0, ROOM_TOP - 0.225, 0), P.MetalRust, { shadow = true })
	decor(s, "IBeamFlange", V(ROOM_HALF_X * 2, 0.1, 0.7), C(0, ROOM_TOP - 0.4, 0), P.MetalRust, { shadow = true })
	decor(s, "Hook", V(0.3, 0.25, 0.3), C(0, BULB_PIVOT_Y + 0.02, 0), P.MetalDark)
end

----------------------------------------------------------------------------
-- Walls: paint, wear, signage
----------------------------------------------------------------------------
local function buildRoomSurfaces(module: Model)
	local t = Builder.getFolder(module, "RoomDecor")
	local north = faceFrame(V(0, FLOOR, -ROOM_HALF_Z), Vector3.zero) -- u = -X
	local south = faceFrame(V(0, FLOOR, ROOM_HALF_Z), Vector3.zero) -- u = +X
	local west = faceFrame(V(TV_WALL_X, FLOOR, 0), Vector3.zero) -- u = +Z
	local mirrorSide = faceFrame(V(14, FLOOR, 0), Vector3.zero) -- u = -Z

	local doorGap = { { DOOR_X - 2.6, DOOR_X + 2.6 } }
	-- North/south runs span the full width; west/mirror runs stop just clear
	-- of each north/south trim's depth (corners close, nothing overlaps).
	local runs = {
		{ frame = north, half = ROOM_HALF_X, gaps = {}, top = 4.2, corner = false },
		{ frame = south, half = ROOM_HALF_X, gaps = doorGap, top = 4.2, corner = false },
		{ frame = west, half = ROOM_HALF_Z, gaps = {}, top = 4.2, corner = true },
		-- under the mirror the paint stops below the sill
		{ frame = mirrorSide, half = ROOM_HALF_Z, gaps = {}, top = 2.4, corner = true },
	}
	for _, run in runs do
		local function span(depth: number): (number, number)
			local inset = if run.corner then depth + 0.01 else 0
			return -run.half + inset, run.half - inset
		end
		local a, b = span(0.12)
		Builder.CreateTrimRun(t, "Wainscot", run.frame, a, b, 0, run.top, 0.02, 0.12, P.FadedGreen, Builder.WidenIntervals(run.gaps, 0.03))
		a, b = span(0.2)
		Builder.CreateTrimRun(t, "Skirting", run.frame, a, b, 0, 0.5, 0.02, 0.2, P.CharcoalDeep, run.gaps)
		if run.top > 3 then
			a, b = span(0.24)
			Builder.CreateTrimRun(t, "Rail", run.frame, a, b, run.top - 0.1, run.top + 0.25, 0.02, 0.24, P.GreenDeep, run.gaps)
		end
	end

	-- Wear: water streak, patched plaster, floor stains, a drain.
	decor(t, "WaterStreak", V(1.2, 6, 0.04), north * C(-8, 8.5, -0.04), P.Stain, { transparency = 0.25 })
	decor(t, "Patch", V(2.6, 1.7, 0.04), north * C(9, 6.5, -0.04), P.ConcreteDark)
	decor(t, "Patch", V(1.8, 2.2, 0.04), west * C(8.5, 6.2, -0.04), P.ConcreteDark)
	decor(t, "Scorch", V(1.4, 1.0, 0.04), south * C(-9, 7.4, -0.04), P.Stain, { transparency = 0.2 })
	local stains = {
		{ size = V(3, 0.02, 2.2), at = V(-3.5, 0, 3.8), yaw = 20 },
		{ size = V(1.6, 0.02, 1.2), at = V(5.2, 0, -4.4), yaw = -35 },
		{ size = V(2.2, 0.02, 1.4), at = V(-9.5, 0, -6.5), yaw = 8 },
	}
	for _, stain in stains do
		decor(t, "FloorStain", stain.size, C(stain.at.X, FLOOR + 0.011, stain.at.Z) * CFrame.Angles(0, math.rad(stain.yaw), 0), P.Stain)
	end
	Builder.CreateCylinder(t, "Drain", 0.03, 1.0, C(10.5, FLOOR + 0.015, -9.5) * Builder.AxisY, P.MetalDark, DECOR)

	Props.CreateSign(north * C(4, 8.6, 0), t, {
		width = 3,
		height = 1,
		text = "NO SMOKING",
		font = P.Font.Sign,
		color = P.Text.Ink,
		plate = P.PaperOld,
		frame = P.MetalDark,
		pixelsPerStud = 40,
		lightInfluence = 1,
		name = "NoSmoking",
	})
	-- Stencilled room name over the door (a transparent carrier for the paint).
	local stencil = decor(t, "Stencil", V(3.4, 0.9, 0.04), south * C(DOOR_X, 10.0, -0.03), P.Charcoal, { transparency = 1 })
	Builder.CreateSurfaceText(stencil, Enum.NormalId.Front, "INTERVIEW  B", {
		font = P.Font.Sign,
		color = P.Text.Stencil,
		pixelsPerStud = 40,
		lightInfluence = 1,
	})
end

----------------------------------------------------------------------------
-- The TV (wall-mounted CRT) and its screen GUI
----------------------------------------------------------------------------
local function addTVLabel(parent: Frame, name: string, text: string, top: number, height: number, font: Enum.Font, color: Color3, glow: Color3)
	local label = Instance.new("TextLabel")
	label.Name = name
	label.BackgroundTransparency = 1
	label.Position = UDim2.fromScale(0.04, top)
	label.Size = UDim2.fromScale(0.92, height)
	label.FontFace = Font.fromEnum(font)
	label.Text = text
	label.TextScaled = true
	label.TextWrapped = true
	label.TextColor3 = color
	label.TextStrokeColor3 = glow
	label.TextStrokeTransparency = 0.55
	label.ZIndex = 2
	label.Parent = parent
end

local function buildTVGui(screen: BasePart)
	local gui = Instance.new("SurfaceGui")
	gui.Name = Names.TVGui
	gui.Face = Enum.NormalId.Front
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 45
	gui.LightInfluence = 0
	gui.Brightness = 1.2
	gui.ClipsDescendants = true
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

	local frame = Instance.new("Frame")
	frame.Name = Names.TVFrame
	frame.Size = UDim2.fromScale(1, 1)
	frame.BackgroundColor3 = P.Text.ScreenBg
	frame.BorderSizePixel = 0
	frame.ClipsDescendants = true
	frame.Parent = gui

	-- Top to bottom: header, category, speaker, answer, footer.
	addTVLabel(frame, Names.TVHeader, "METRO P.D.  //  CASE 64", 0.04, 0.11, P.Font.Display, P.Neon.Amber, P.Neon.AmberDim)
	addTVLabel(frame, Names.TVCategory, "STAND BY", 0.18, 0.2, P.Font.Display, P.Neon.Phosphor, P.Neon.PhosphorDim)
	addTVLabel(frame, Names.TVSpeaker, "", 0.41, 0.11, P.Font.Mono, P.Neon.Amber, P.Neon.AmberDim)
	addTVLabel(frame, Names.TVAnswer, "", 0.54, 0.26, P.Font.Display, P.Neon.Phosphor, P.Neon.PhosphorDim)
	addTVLabel(frame, Names.TVFooter, "NO REPEATS  /  NO HESITATION", 0.85, 0.09, P.Font.Terminal, P.Neon.PhosphorDim, P.Text.ScreenBg)

	-- Empty noise layer the client fills and toggles (above every label).
	local static = Instance.new("Frame")
	static.Name = Names.TVStatic
	static.Size = UDim2.fromScale(1, 1)
	static.BackgroundColor3 = Color3.fromRGB(18, 20, 18)
	static.BorderSizePixel = 0
	static.ClipsDescendants = true
	static.Visible = false
	static.ZIndex = 10
	static.Parent = frame

	gui.Parent = screen
end

local function buildTV(module: Model)
	local d = Builder.getFolder(module, "RoomDecor")
	local caseBack = TV_WALL_X + 0.02 -- the case sits 0.02 off the wall
	local caseFront = caseBack + 1.2 -- -12.78
	local bezelFront = caseFront + 0.5 -- -12.28

	box(d, "TVCase", V(1.2, 7.6, 12), C((caseBack + caseFront) / 2, TV_CENTER_Y, 0), P.CaseDark)
	-- Screen: Front face (+X) is the glass; 10 wide × 6 tall, centred at Y 8.
	local screenCF = CFrame.lookAt(V(caseFront + 0.1, TV_CENTER_Y, 0), V(0, TV_CENTER_Y, 0))
	local screen = decor(module, Names.TVScreen, V(10, 6, 0.2), screenCF, P.ScreenOff, { reflectance = 0.05 })
	buildTVGui(screen)
	Builder.AddSurfaceLight(screen, {
		name = "TVGlow",
		color = P.Light.TV,
		brightness = 0.6,
		range = 16,
		angle = 110,
		face = Enum.NormalId.Front,
	})

	-- Bezel bars stand 0.3 proud of the glass so it reads as a deep tube.
	local bezelX = (caseFront + bezelFront) / 2
	decor(d, "Bezel", V(0.5, 0.8, 12), C(bezelX, TV_CENTER_Y + 3.4, 0), P.CaseDark, { shadow = true })
	decor(d, "Bezel", V(0.5, 0.8, 12), C(bezelX, TV_CENTER_Y - 3.4, 0), P.CaseDark, { shadow = true })
	for _, side in { -1, 1 } do
		decor(d, "Bezel", V(0.5, 6, 1), C(bezelX, TV_CENTER_Y, side * 5.5), P.CaseDark, { shadow = true })
		-- Triangular knee brackets under the set: the right angle sits at the
		-- top against the wall (wedge turned to face +X, then flipped).
		local bracketCF = C(TV_WALL_X + 0.82, TV_CENTER_Y - 4.7, side * 4) * CFrame.Angles(0, math.rad(90), 0) * CFrame.Angles(math.pi, 0, 0)
		Builder.CreateWedge(d, "Bracket", V(0.3, 1.8, 1.4), bracketCF, P.MetalDark, DECOR)
	end
	for _, z in { 4.1, 4.8 } do
		Builder.CreateCylinder(d, "Knob", 0.14, 0.3, C(bezelFront + 0.06, TV_CENTER_Y - 3.4, z), P.Chrome, DECOR)
	end
	local badge = decor(d, "Badge", V(0.04, 0.4, 2.6), C(bezelFront + 0.02, TV_CENTER_Y - 3.4, -2), P.Brass)
	Builder.CreateSurfaceText(badge, Enum.NormalId.Right, "ZENOTRON 64", {
		font = P.Font.Plaque,
		color = P.Text.Ink,
		pixelsPerStud = 40,
		lightInfluence = 1,
	})
end

----------------------------------------------------------------------------
-- Table, chairs (Seats) and the hanging bulb
----------------------------------------------------------------------------
local function buildFurniture(module: Model)
	local d = Builder.getFolder(module, "RoomDecor")
	local seats = Builder.getFolder(module, Names.Seats)

	Props.CreateTable(C(0, FLOOR, 0), d, { width = 10, depth = 7, height = TABLE_TOP - FLOOR, style = "Metal", name = "InterrogationTable" })
	-- Table clutter, kept away from the centre so the bulb pool stays clean.
	Props.CreateMicrophone(CFrame.lookAt(V(-3.2, TABLE_TOP, 1.6), V(0, TABLE_TOP, 4)), d)
	Props.CreatePaperStack(C(2.6, TABLE_TOP, 1.4) * CFrame.Angles(0, math.rad(-12), 0), d, { seed = 64, sheets = 2, folder = true })
	Builder.CreatePost(d, "Ashtray", V(3.4, TABLE_TOP, -2.2), 0.12, 0.6, P.MetalDark, DECOR)
	Builder.CreatePost(d, "Cup", V(-3.6, TABLE_TOP, -2.0), 0.45, 0.36, P.Ceramic, DECOR)
	decor(d, "CuffBolt", V(0.5, 0.06, 0.5), C(0, TABLE_TOP + 0.03, 0), P.MetalDark)
	decor(d, "CuffLoop", V(0.08, 0.35, 0.45), C(0, TABLE_TOP + 0.2, 0), P.Chrome)

	for index, position in SEATS do
		local chairCF = CFrame.lookAt(V(position.X, FLOOR, position.Z), V(0, FLOOR, 0))
		local chair = Props.CreateChair(chairCF, d, { style = "Metal", seatName = Names.SeatAnchor(index) })
		chair.Name = `Chair{index}`
		local seat = chair:FindFirstChild(Names.SeatAnchor(index))
		assert(seat and seat:IsA("Seat"), "chair seat missing")
		seat.Parent = seats
	end
end

local function buildBulb(module: Model)
	Builder.CreateMarker(module, Names.BulbPivot, C(0, BULB_PIVOT_Y, 0), V(0.4, 0.4, 0.4))

	local assembly = Builder.newModel(Names.BulbAssembly)
	local bulbY = BULB_PIVOT_Y - BULB_DROP -- 8.55
	Builder.CreateCylinderBetween(assembly, "Cable", V(0, BULB_PIVOT_Y - 0.2, 0), V(0, bulbY + 0.9, 0), 0.08, P.Rubber, DECOR)
	Builder.CreatePost(assembly, "Socket", V(0, bulbY + 0.3, 0), 0.6, 0.38, P.Brass, DECOR)
	-- A tin shade above the bulb throws the ceiling into shadow while it swings.
	Builder.CreatePost(assembly, "Shade", V(0, bulbY + 0.42, 0), 0.22, 1.9, P.MetalOxidised, { decor = true, shadow = true })
	local bulb = Builder.CreateBall(assembly, Names.Bulb, 0.7, C(0, bulbY, 0), { Color = P.Neon.Bulb, Material = Enum.Material.Neon }, DECOR)
	Builder.AddPointLight(bulb, {
		name = Names.BulbLight,
		color = P.Light.Bulb,
		brightness = Config.Visual.BulbBrightness,
		range = 24,
		shadows = true,
	})
	assembly.PrimaryPart = bulb
	assembly.Parent = module
end

----------------------------------------------------------------------------
-- Room lights the client tints on eliminations
----------------------------------------------------------------------------
local function buildRoomLights(module: Model)
	local lights = Builder.getFolder(module, Names.RoomLights)
	local d = Builder.getFolder(module, "RoomDecor")

	-- Dim cool fill panel near the TV wall so the room is never pitch black.
	decor(d, "FillHousing", V(4.4, 0.12, 1.6), C(-10.5, ROOM_TOP - 0.08, 0), P.MetalDark)
	local fill = Builder.CreateNeon(lights, "FillLight", V(4, 0.25, 1.2), C(-10.5, ROOM_TOP - 0.145, 0), P.Neon.RoomFill)
	Builder.AddSurfaceLight(fill, {
		name = "Fill",
		color = P.Light.Cool,
		brightness = 0.4,
		range = 20,
		angle = 120,
		face = Enum.NormalId.Bottom,
	})

	-- Thin alarm strip along the top of the TV wall (dark until an elimination).
	-- Its light starts disabled at Brightness 0: the client switches it on and
	-- raises the brightness for the red pulse, then restores these values.
	local strip = Builder.CreateNeon(lights, "AlarmStrip", V(0.15, 0.25, ROOM_HALF_Z * 2 - 2), C(TV_WALL_X + 0.1, 13.5, 0), P.Neon.AlarmDim)
	Builder.AddPointLight(strip, {
		name = "AlarmLight",
		color = P.Light.Alarm,
		brightness = 0,
		range = 26,
		enabled = false,
	})
end

----------------------------------------------------------------------------
-- Door, mirror, fixtures and equipment
----------------------------------------------------------------------------
local function buildMirror(module: Model)
	local s = Builder.getFolder(module, "RoomStructure")
	local height = MIRROR_TOP - MIRROR_BOTTOM
	local midY = (MIRROR_TOP + MIRROR_BOTTOM) / 2
	box(module, Names.TwoWayMirror, V(0.4, height, MIRROR_HALF_Z * 2), C(MIRROR_X, midY, 0), P.GlassMirror, {
		transparency = 0.35,
		reflectance = 0.25,
		shadow = false,
	})
	-- Frames on both faces of the dividing wall (room face X 14, lounge X 15).
	for _, side in { -1, 1 } do
		local face = MIRROR_X + side * 0.5
		local out = side * 0.17
		decor(s, "MirrorFrame", V(0.3, 0.5, MIRROR_HALF_Z * 2 + 1), C(face + out, MIRROR_TOP + 0.25, 0), P.MetalDark)
		for _, z in { -1, 1 } do
			decor(s, "MirrorFrame", V(0.3, height, 0.5), C(face + out, midY, z * (MIRROR_HALF_Z + 0.25)), P.MetalDark)
		end
		local sillDepth = if side < 0 then 0.6 else 0.8
		box(s, "MirrorSill", V(sillDepth, 0.3, MIRROR_HALF_Z * 2 + 1.4), C(face + side * sillDepth / 2, MIRROR_BOTTOM - 0.15, 0), P.MetalDark)
	end
end

local function buildRoomEquipment(module: Model)
	local d = Builder.getFolder(module, "RoomDecor")

	-- Heavy steel door in the south wall: the slab IS Names.RoomDoor.
	local door = Props.CreateDoor(CFrame.lookAt(V(DOOR_X, FLOOR, ROOM_HALF_Z), V(DOOR_X, FLOOR, 0)), d, {
		kind = "Metal",
		width = 4,
		height = 8.6,
		slabName = Names.RoomDoor,
		window = true,
	})
	local slab = door:FindFirstChild(Names.RoomDoor)
	assert(slab and slab:IsA("BasePart"), "door slab missing")
	slab.Parent = module

	Props.CreateWallClock(CFrame.lookAt(V(4, 10.6, -ROOM_HALF_Z), V(4, 10.6, 0)), d, { diameter = 2, hour = 3, minute = 7 })
	Props.CreateVent(CFrame.lookAt(V(TV_WALL_X, 12.4, -9.5), V(0, 12.4, -9.5)), d, { width = 2.4, height = 1.6 })
	Props.CreateVent(Builder.facing(V(-4, ROOM_TOP, 7), V(0, -1, 0)), d, { width = 2.4, height = 2.4 })
	Props.CreatePipeRun(CFrame.identity, {
		V(TV_WALL_X - 0.05, 12.6, -ROOM_HALF_Z + 0.5),
		V(13.3, 12.6, -ROOM_HALF_Z + 0.5),
		V(13.3, FLOOR, -ROOM_HALF_Z + 0.5),
	}, d, { diameter = 0.5, swatch = P.MetalOxidised, clampEvery = 9 })
	decor(d, "JunctionBox", V(1, 1.2, 0.4), C(10, 11, -ROOM_HALF_Z + 0.22), P.MetalOxidised)

	-- Recording equipment on a cart in the north-west corner.
	Props.CreateRecorder(CFrame.lookAt(V(-11, FLOOR, -9.6), V(0, FLOOR, 0)), d)
	-- CCTV high in the south-west corner, watching the table.
	Props.CreateSecurityCamera(CFrame.lookAt(V(-12.5, 13.0, ROOM_HALF_Z), V(-12.5, 13.0, 0)), V(0, TABLE_TOP, 0), d)
end

local function buildRoomCameras(module: Model)
	local cams = Builder.getFolder(module, Names.CameraAnchors)
	-- CFrame IS the camera (LookVector = view direction). Framing was checked
	-- for a 60° vertical FOV at 16:9: the whole table, all four seats and the
	-- TV fit inside the InterrogationCamera frame with margin.
	cameraAnchor(cams, Names.IntroCamera, V(7, 6.8, 10.6), V(-3.5, 4.4, -1.2))
	cameraAnchor(cams, Names.InterrogationCamera, V(12.6, 11.4, 9.6), V(-3.6, 3.6, -0.8))
	cameraAnchor(cams, Names.CallerCamera, V(10, 10.6, 8), V(-5.5, 4.2, -0.8))
	cameraAnchor(cams, Names.VictoryCamera, V(7.5, 2.4, 9.5), V(-1.5, 6.4, -1.5))
end

----------------------------------------------------------------------------
-- Spectator lounge
----------------------------------------------------------------------------
local LOUNGE_CENTER_X = (LOUNGE_MIN_X + LOUNGE_MAX_X) / 2 -- 22
local DESK_X = 23.5

local function buildLoungeShell(module: Model)
	local s = Builder.getFolder(module, "LoungeStructure")
	local d = Builder.getFolder(module, "LoungeDecor")
	local wallHeight = LOUNGE_TOP + 1 + 0.8 -- from -0.8 to the top of the lounge ceiling
	local span = LOUNGE_MAX_X + 1 - LOUNGE_MIN_X -- 15 (X 15..30)

	Builder.CreateFloor(s, "LoungeFloor", V((MIRROR_X + LOUNGE_MAX_X + 1) / 2, FLOOR, 0), LOUNGE_MAX_X + 1 - MIRROR_X, ROOM_HALF_Z * 2 + 2, P.FabricCharcoal)
	for _, side in { -1, 1 } do
		local z = side * (ROOM_HALF_Z + 0.5)
		Builder.CreateWall(s, "LoungeWall", V(LOUNGE_MIN_X, -0.8, z), V(LOUNGE_MIN_X + span, -0.8, z), wallHeight, 1, P.ConcreteDark)
	end
	local eastX = LOUNGE_MAX_X + 0.5
	Builder.CreateWall(s, "LoungeWall", V(eastX, -0.8, -ROOM_HALF_Z), V(eastX, -0.8, ROOM_HALF_Z), wallHeight, 1, P.ConcreteDark)
	box(s, "LoungeCeiling", V(span, 1, ROOM_HALF_Z * 2 + 2), C(LOUNGE_MIN_X + span / 2, LOUNGE_TOP + 0.5, 0), P.Ceiling)

	-- Acoustic fabric panels (the east wall is split around the door).
	local panelLength = LOUNGE_MAX_X - LOUNGE_MIN_X - 0.1
	for _, side in { -1, 1 } do
		decor(d, "AcousticPanel", V(panelLength, 9, 0.12), C(LOUNGE_CENTER_X, 6, side * (ROOM_HALF_Z - 0.08)), P.FabricCharcoal)
	end
	decor(d, "AcousticPanel", V(0.12, 9, 15.9), C(LOUNGE_MAX_X - 0.08, 6, -3.9), P.FabricCharcoal)
	decor(d, "AcousticPanel", V(0.12, 9, 2.1), C(LOUNGE_MAX_X - 0.08, 6, 10.85), P.FabricCharcoal)
	decor(d, "Dado", V(0.1, 2.5, ROOM_HALF_Z * 2 - 0.2), C(LOUNGE_MIN_X + 0.07, FLOOR + 1.25, 0), P.CharcoalDeep)

	-- One dim cool lamp: the lounge stays dark so the lit room "glows".
	Builder.CreatePost(d, "LampCap", V(LOUNGE_CENTER_X, LOUNGE_TOP - 0.35, 0), 0.35, 0.5, P.MetalDark, DECOR)
	local lamp = Builder.CreateBall(d, "LoungeLamp", 0.6, C(LOUNGE_CENTER_X, LOUNGE_TOP - 0.55, 0), {
		Color = P.Neon.LoungeLamp,
		Material = Enum.Material.Neon,
	}, DECOR)
	Builder.AddPointLight(lamp, { name = "LoungeLight", color = P.Light.Cool, brightness = 0.55, range = 18 })
end

local function buildLoungeFurniture(module: Model)
	local d = Builder.getFolder(module, "LoungeDecor")
	local crts = Builder.getFolder(module, Names.CRTs)

	-- Observation desk against the north wall with CRT security monitors.
	local deskBack = -ROOM_HALF_Z + 0.15
	box(d, "ObservationDesk", V(10, 0.25, 2.4), C(DESK_X, FLOOR + 2.875, deskBack + 1.2), P.WoodDark)
	box(d, "DeskBody", V(10, 2.75, 2.0), C(DESK_X, FLOOR + 1.375, deskBack + 1.0), P.CharcoalDeep)
	local deskTop = FLOOR + 3.0
	for _, x in { DESK_X - 3, DESK_X, DESK_X + 3 } do
		Props.CreateCRTMonitor(CFrame.lookAt(V(x, deskTop, deskBack + 1.25), V(x, deskTop, 0)), crts, { width = 1.9, kind = "Monitor", case = P.CaseDark })
		Props.CreateStool(C(x, FLOOR, -7.6), d)
	end
	box(d, "MonitorShelf", V(8, 0.2, 1.6), C(DESK_X, FLOOR + 6.7, deskBack + 0.8), P.MetalDark)
	for _, x in { DESK_X - 3.6, DESK_X + 3.6 } do
		-- Wedge brackets: flipped so the right angle is under the shelf at the wall.
		Builder.CreateWedge(d, "ShelfBracket", V(0.2, 1.2, 1.4), C(x, FLOOR + 6.0, deskBack + 0.7) * CFrame.Angles(math.pi, 0, 0), P.MetalDark, DECOR)
	end
	for _, x in { DESK_X - 2, DESK_X + 2 } do
		Props.CreateCRTMonitor(CFrame.lookAt(V(x, FLOOR + 6.8, deskBack + 0.85), V(x, FLOOR + 6.8, 0)), crts, { width = 1.7, kind = "Monitor", case = P.CaseDark })
	end
	local label = decor(d, "Stencil", V(6, 1, 0.04), C(DESK_X, FLOOR + 9.6, -ROOM_HALF_Z + 0.2), P.Charcoal, { transparency = 1 })
	Builder.CreateSurfaceText(label, Enum.NormalId.Back, "OBSERVATION", {
		font = P.Font.Sign,
		color = P.Text.Stencil,
		pixelsPerStud = 40,
		lightInfluence = 1,
	})

	-- Guard rail two studs from the glass (blocks walking right up to it).
	Props.CreateRailing(C(LOUNGE_MIN_X + 2, FLOOR, 0) * CFrame.Angles(0, math.rad(90), 0), d, { length = 21, height = 3.6, spacing = 5.25 })

	Props.CreateBench(CFrame.lookAt(V(DESK_X, FLOOR, ROOM_HALF_Z - 1.1), V(DESK_X, FLOOR, 0)), d, { width = 7 })
	Props.CreateDoor(CFrame.lookAt(V(LOUNGE_MAX_X, FLOOR, 7), V(0, FLOOR, 7)), d, { kind = "Metal", width = 3.6, height = 8, window = true })
	Props.CreateTrashBin(C(LOUNGE_MAX_X - 1.2, FLOOR, 2.2), d)

	-- Wall-mounted CCTV watching the spectators.
	Props.CreateSecurityCamera(CFrame.lookAt(V(LOUNGE_MAX_X, 11.2, -10.5), V(0, 11.2, -10.5)), V(18, FLOOR + 2, 0), d)
	Props.CreateSecurityCamera(CFrame.lookAt(V(18, 11.2, ROOM_HALF_Z), V(18, 11.2, 0)), V(24, FLOOR + 2, -2), d)
end

local function buildLoungeMarkers(module: Model)
	local spawns = Builder.getFolder(module, Names.SpectatorSpawns)
	for index, z in { -4.5, -1.5, 1.5, 4.5 } do
		-- On the lounge floor, facing -X toward the mirror.
		local at = V(23, FLOOR + 0.12, z)
		Builder.CreateMarker(spawns, Names.SpectatorSpawn(index), CFrame.lookAt(at, at - Vector3.xAxis), V(2, 0.2, 2))
	end

	local cams = Builder.getFolder(module, Names.CameraAnchors)
	-- Every spectator camera looks through the mirror opening.
	cameraAnchor(cams, Names.SpectatorCameras[1], V(21, 8.5, 0), V(-4.5, 5.2, 0))
	cameraAnchor(cams, Names.SpectatorCameras[2], V(28, 10.4, 9.5), V(-4, 4.5, -1.5))
	cameraAnchor(cams, Names.SpectatorCameras[3], V(18.4, 5.4, -8), V(-6, 5, 2.5))
end

----------------------------------------------------------------------------
-- Public
----------------------------------------------------------------------------

-- Adds the interrogation room to `module` (module-local coordinates).
function InterrogationModule.CreateInterrogationRoom(module: Model): Model
	buildRoomShell(module)
	buildRoomSurfaces(module)
	buildMirror(module)
	buildTV(module)
	buildFurniture(module)
	buildBulb(module)
	buildRoomLights(module)
	buildRoomEquipment(module)
	buildRoomCameras(module)
	return module
end

-- Adds the spectator lounge behind the mirror to `module`.
function InterrogationModule.CreateSpectatorLounge(module: Model): Model
	buildLoungeShell(module)
	buildLoungeFurniture(module)
	buildLoungeMarkers(module)
	return module
end

-- Builds the full template at Config.Match.RoomOrigin and parents it.
function InterrogationModule.CreateModuleTemplate(parent: Instance?): Model
	local module = Builder.newModel(Names.Template)
	local root = Builder.CreateMarker(module, Names.ModuleRoot, CFrame.identity, V(1, 0.4, 1))
	module.PrimaryPart = root

	InterrogationModule.CreateInterrogationRoom(module)
	InterrogationModule.CreateSpectatorLounge(module)

	module:PivotTo(CFrame.new(Config.Match.RoomOrigin))
	module.Parent = parent
	return module
end

return InterrogationModule
