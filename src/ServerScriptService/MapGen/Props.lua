--!strict
--[[
	Props  (ModuleScript)  ·  ServerScriptService/MapGen/Props

	Low-poly PS1-noir furniture and fixtures. Every prop:
	  • is a Model built around a LOCAL origin on the floor (y = 0);
	  • faces -Z (the pivot's LookVector): the side a person uses / looks at;
	  • is then pivoted with Builder.place(model, cf, parent).

	Wall-mounted props (clocks, vents, signs, boards, cameras, doors) use the
	wall surface as their origin, with -Z pointing out of the wall into the
	room. Pass a CFrame built with CFrame.lookAt(wallPoint, wallPoint + inward).

	Collision policy: surfaces people could walk into or stand on collide
	(seat pans, table tops, couch bodies, cabinets, shelves). Small pieces
	(legs, handles, trims, cables, knobs) are decor: no collision, no query,
	no touch, no shadow.
]]

local Builder = require(script.Parent.Builder)
local Palette = require(script.Parent.Palette)

local ReplicatedStorage = game:GetService("ReplicatedStorage")
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

local Props = {}

local function darker(swatch: Swatch, amount: number): PartFlags
	return { decor = true, color = swatch.Color:Lerp(Color3.new(0, 0, 0), amount) }
end

----------------------------------------------------------------------------
-- Seating
----------------------------------------------------------------------------
export type ChairOptions = {
	style: ("Metal" | "Wood")?,
	seatName: string?, -- when given, the seat pan is a real Seat with this name
}

-- Low-poly chair. Seat pan top at y = 2.0; the sitter faces -Z.
function Props.CreateChair(cf: CFrame, parent: Instance?, options: ChairOptions?): Model
	local o: ChairOptions = options or {}
	local model = Builder.newModel("Chair")
	local frame = if o.style == "Wood" then P.WoodDark else P.MetalDark
	local pan = if o.style == "Wood" then P.Wood else P.MetalOxidised

	local seatSize, seatCF = V(2, 0.3, 2), C(0, 1.85, 0)
	if o.seatName then
		Builder.CreateSeat(model, o.seatName, seatSize, seatCF, pan)
	else
		box(model, "SeatPan", seatSize, seatCF, pan)
	end
	for _, x in { -0.85, 0.85 } do
		decor(model, "Leg", V(0.2, 1.7, 0.2), C(x, 0.85, -0.85), frame)
		decor(model, "BackLeg", V(0.2, 3.9, 0.2), C(x, 1.95, 0.85), frame)
	end
	decor(model, "Backrest", V(1.5, 1.3, 0.16), C(0, 3.05, 0.85), pan)
	decor(model, "Stretcher", V(1.5, 0.14, 0.14), C(0, 0.55, 0.85), frame)
	return Builder.place(model, cf, parent)
end

export type CouchOptions = {
	seats: number?,
	swatch: Swatch?,
	name: string?,
}

-- Upholstered couch (seats: 1 = armchair). Cushion top at y = 1.8.
function Props.CreateCouch(cf: CFrame, parent: Instance?, options: CouchOptions?): Model
	local o: CouchOptions = options or {}
	local seats = o.seats or 3
	local fabric = o.swatch or P.Leather
	local width = seats * 2.2
	local model = Builder.newModel(o.name or (if seats == 1 then "Armchair" else "Couch"))

	box(model, "Base", V(width, 1.35, 2.6), C(0, 0.675, 0), fabric)
	for index = 1, seats do
		local x = -width / 2 + 1.1 + (index - 1) * 2.2
		box(model, "Cushion", V(2.1, 0.45, 2.0), C(x, 1.575, -0.25), fabric)
	end
	box(model, "Back", V(width, 2.1, 0.7), C(0, 2.4, 0.95), fabric)
	for _, side in { -1, 1 } do
		box(model, "Arm", V(0.7, 1.85, 2.6), C(side * (width / 2 + 0.35), 0.925, 0), fabric)
	end
	return Builder.place(model, cf, parent)
end

function Props.CreateArmchair(cf: CFrame, parent: Instance?, swatch: Swatch?): Model
	return Props.CreateCouch(cf, parent, { seats = 1, swatch = swatch, name = "Armchair" })
end

-- Industrial bar stool. Seat top at y = 2.4.
function Props.CreateStool(cf: CFrame, parent: Instance?): Model
	local model = Builder.newModel("Stool")
	Builder.CreatePost(model, "Base", Vector3.zero, 0.15, 1.3, P.MetalDark, DECOR)
	Builder.CreatePost(model, "Post", V(0, 0.15, 0), 2.0, 0.22, P.Metal, DECOR)
	decor(model, "FootBar", V(1.1, 0.08, 0.08), C(0, 0.9, 0), P.Metal)
	decor(model, "FootBar", V(0.08, 0.08, 1.1), C(0, 0.9, 0), P.Metal)
	Builder.CreatePost(model, "Seat", V(0, 2.15, 0), 0.25, 1.3, P.MetalOxidised)
	return Builder.place(model, cf, parent)
end

export type BenchOptions = { width: number? }

-- Slatted waiting bench with a backrest. Seat top at y = 1.83.
function Props.CreateBench(cf: CFrame, parent: Instance?, options: BenchOptions?): Model
	local width = (options and options.width) or 6
	local model = Builder.newModel("Bench")
	box(model, "Seat", V(width, 0.25, 1.4), C(0, 1.7, 0), P.WoodPlanks)
	box(model, "Back", V(width, 1.0, 0.2), C(0, 2.7, 0.6), P.WoodPlanks)
	for _, x in { -(width / 2 - 0.5), width / 2 - 0.5 } do
		decor(model, "Support", V(0.25, 1.575, 1.2), C(x, 0.7875, 0), P.MetalDark)
		decor(model, "BackPost", V(0.2, 1.2, 0.2), C(x, 2.3, 0.72), P.MetalDark)
	end
	return Builder.place(model, cf, parent)
end

----------------------------------------------------------------------------
-- Tables and desks
----------------------------------------------------------------------------
export type TableOptions = {
	width: number?,
	depth: number?,
	height: number?,
	style: ("Metal" | "Wood")?,
	name: string?,
}

-- Rectangular table with a chunky edge band and heavy square legs.
function Props.CreateTable(cf: CFrame, parent: Instance?, options: TableOptions?): Model
	local o: TableOptions = options or {}
	local w, d, h = o.width or 6, o.depth or 3.5, o.height or 3
	local metal = o.style ~= "Wood"
	local topSwatch = if metal then P.MetalOxidised else P.Wood
	local legSwatch = if metal then P.MetalDark else P.WoodDark
	local model = Builder.newModel(o.name or "Table")

	box(model, "Top", V(w, 0.3, d), C(0, h - 0.15, 0), topSwatch)
	decor(model, "Edge", V(w + 0.3, 0.35, d + 0.3), C(0, h - 0.475, 0), legSwatch, { shadow = true })
	local legHeight = h - 0.65
	local lx, lz = w / 2 - 0.6, d / 2 - 0.6
	for _, x in { -lx, lx } do
		for _, z in { -lz, lz } do
			decor(model, "Leg", V(0.7, legHeight, 0.7), C(x, legHeight / 2, z), legSwatch, { shadow = true })
			decor(model, "Foot", V(1.0, 0.1, 1.0), C(x, 0.05, z), legSwatch)
		end
	end
	if metal then
		for _, z in { -lz, lz } do
			decor(model, "Brace", V(lx * 2, 0.25, 0.25), C(0, 0.8, z), legSwatch)
		end
	end
	return Builder.place(model, cf, parent)
end

export type CoffeeTableOptions = { width: number?, depth: number?, clutter: boolean? }

function Props.CreateCoffeeTable(cf: CFrame, parent: Instance?, options: CoffeeTableOptions?): Model
	local o: CoffeeTableOptions = options or {}
	local w, d = o.width or 4, o.depth or 2.4
	local model = Builder.newModel("CoffeeTable")
	box(model, "Top", V(w, 0.25, d), C(0, 1.425, 0), P.WoodDark)
	decor(model, "Shelf", V(w - 0.6, 0.12, d - 0.6), C(0, 0.45, 0), P.Wood)
	for _, x in { -(w / 2 - 0.25), w / 2 - 0.25 } do
		for _, z in { -(d / 2 - 0.25), d / 2 - 0.25 } do
			decor(model, "Leg", V(0.25, 1.3, 0.25), C(x, 0.65, z), P.WoodDark)
		end
	end
	if o.clutter ~= false then
		Builder.CreatePost(model, "Ashtray", V(w * 0.25, 1.55, 0.2), 0.12, 0.6, P.MetalDark, DECOR)
		decor(model, "Magazine", V(0.9, 0.04, 1.2), C(-w * 0.2, 1.57, 0) * CFrame.Angles(0, math.rad(14), 0), P.PaperOld)
		decor(model, "Magazine", V(0.9, 0.04, 1.2), C(-w * 0.22, 1.61, 0.1) * CFrame.Angles(0, math.rad(-9), 0), P.RedDesat)
	end
	return Builder.place(model, cf, parent)
end

export type DeskOptions = { width: number?, depth: number?, height: number?, swatch: Swatch? }

-- Office desk: drawer pedestal on the right, modesty panel at the back.
-- The person using it sits on the -Z side.
function Props.CreateDesk(cf: CFrame, parent: Instance?, options: DeskOptions?): Model
	local o: DeskOptions = options or {}
	local w, d, h = o.width or 6, o.depth or 3, o.height or 3
	local wood = o.swatch or P.Wood
	local model = Builder.newModel("Desk")
	box(model, "Top", V(w, 0.25, d), C(0, h - 0.125, 0), wood)
	local bodyHeight = h - 0.25
	local pedestalX = w / 2 - 0.95
	box(model, "Pedestal", V(1.7, bodyHeight, d - 0.3), C(pedestalX, bodyHeight / 2, 0), P.WoodDark)
	box(model, "Side", V(0.2, bodyHeight, d - 0.3), C(-(w / 2 - 0.25), bodyHeight / 2, 0), P.WoodDark)
	decor(model, "Modesty", V(w - 0.6, bodyHeight * 0.6, 0.15), C(0, bodyHeight * 0.6, d / 2 - 0.3), P.WoodDark)
	local drawerHeight = bodyHeight / 3
	for index = 1, 3 do
		local y = (index - 0.5) * drawerHeight
		decor(model, "Drawer", V(1.5, drawerHeight - 0.12, 0.05), C(pedestalX, y, -(d - 0.3) / 2 - 0.025), wood)
		decor(model, "Pull", V(0.5, 0.08, 0.1), C(pedestalX, y + drawerHeight * 0.2, -(d - 0.3) / 2 - 0.1), P.Brass)
	end
	return Builder.place(model, cf, parent)
end

----------------------------------------------------------------------------
-- Storage
----------------------------------------------------------------------------
export type CabinetOptions = { drawers: number?, swatch: Swatch? }

-- Steel filing cabinet; drawers face -Z.
function Props.CreateFilingCabinet(cf: CFrame, parent: Instance?, options: CabinetOptions?): Model
	local o: CabinetOptions = options or {}
	local drawers = o.drawers or 4
	local steel = o.swatch or P.MetalOxidised
	local w, d = 1.9, 2.4
	local h = drawers * 1.2 + 0.25
	local model = Builder.newModel("FilingCabinet")
	box(model, "Body", V(w, h, d), C(0, h / 2, 0), steel)
	for index = 1, drawers do
		local y = 0.2 + (index - 0.5) * 1.2
		decor(model, "Drawer", V(w - 0.2, 1.05, 0.06), C(0, y, -d / 2 - 0.03), steel, darker(steel, 0.12))
		decor(model, "Handle", V(0.6, 0.1, 0.12), C(0, y + 0.22, -d / 2 - 0.12), P.Chrome)
	end
	return Builder.place(model, cf, parent)
end

export type ShelfOptions = {
	width: number?,
	height: number?,
	depth: number?,
	levels: number?,
	boxes: boolean?,
	seed: number?,
}

-- Industrial steel shelving, optionally loaded with archive boxes.
-- Returns the model and the Y of each shelf surface (for callers that load it).
function Props.CreateShelf(cf: CFrame, parent: Instance?, options: ShelfOptions?): (Model, { number })
	local o: ShelfOptions = options or {}
	local w, h, d = o.width or 6, o.height or 8, o.depth or 2
	local levels = math.max(2, o.levels or 4)
	local model = Builder.newModel("Shelf")
	for _, x in { -(w / 2 - 0.1), w / 2 - 0.1 } do
		for _, z in { -(d / 2 - 0.1), d / 2 - 0.1 } do
			decor(model, "Upright", V(0.18, h, 0.18), C(x, h / 2, z), P.MetalOxidised, { shadow = true })
		end
	end
	local shelfTops: { number } = {}
	for index = 1, levels do
		local y = 0.4 + (index - 1) * (h - 0.6) / (levels - 1)
		box(model, "Shelf", V(w, 0.1, d), C(0, y, 0), P.MetalDark)
		table.insert(shelfTops, y + 0.05)
	end
	if o.boxes ~= false then
		local rng = Random.new(o.seed or 7)
		for index = 1, levels - 1 do
			local cursor = -w / 2 + 0.3
			while cursor < w / 2 - 1.2 do
				local bw = rng:NextNumber(0.9, 1.6)
				if cursor + bw > w / 2 - 0.25 then
					break
				end
				if rng:NextNumber() < 0.8 then
					local bh = rng:NextNumber(0.7, math.min(1.3, (h - 0.6) / (levels - 1) - 0.25))
					local bd = d - rng:NextNumber(0.3, 0.6)
					local tint = if rng:NextNumber() < 0.3 then P.Manila else P.Cardboard
					local yaw = math.rad(rng:NextNumber(-6, 6))
					local y = shelfTops[index] + bh / 2 + 0.01
					decor(model, "Box", V(bw, bh, bd), C(cursor + bw / 2, y, 0) * CFrame.Angles(0, yaw, 0), tint)
				end
				cursor += bw + rng:NextNumber(0.08, 0.35)
			end
		end
	end
	return Builder.place(model, cf, parent), shelfTops
end

----------------------------------------------------------------------------
-- Screens
----------------------------------------------------------------------------
export type CRTOptions = {
	width: number?, -- screen width in studs (height is 3:4 of it)
	kind: ("TV" | "Monitor")?,
	case: Swatch?,
	screenText: string?, -- static terminal text drawn on the glass
	antenna: boolean?,
	name: string?,
}

-- Chunky cathode-ray tube. The glass is a part named Names.CRTScreen whose
-- Front face (-Z, the prop's front) is the visible screen. Sits on y = 0.
function Props.CreateCRTMonitor(cf: CFrame, parent: Instance?, options: CRTOptions?): Model
	local o: CRTOptions = options or {}
	local w = o.width or 2.4
	local h = w * 0.75
	local kind = o.kind or "TV"
	local case = o.case or (if kind == "TV" then P.CaseDark else P.CaseBeige)
	local depth = w * 0.85
	local chin = if kind == "TV" then 0.55 else 0.25
	local frontZ = -depth / 2
	local screenY = chin + 0.15 + h / 2
	local model = Builder.newModel(o.name or "CRT")

	local bezelHeight = h + 0.3 + chin
	box(model, "Bezel", V(w + 0.5, bezelHeight, 0.6), C(0, bezelHeight / 2, frontZ + 0.3), case)
	-- Tapered tube housing: a wedge whose tall face sits against the bezel.
	local rearHeight = h * 0.85
	local rearCF = C(0, screenY - 0.05, frontZ + 0.6 + (depth - 0.6) / 2) * CFrame.Angles(0, math.pi, 0)
	Builder.CreateWedge(model, "Rear", V(w * 0.8, rearHeight, depth - 0.6), rearCF, case, { decor = true, shadow = true })

	local screen = decor(model, Names.CRTScreen, V(w, h, 0.1), C(0, screenY, frontZ - 0.01), P.ScreenOff, {
		reflectance = 0.08,
	})

	if kind == "TV" then
		-- Rims stand proud of the glass so it reads as recessed in the bezel.
		local rim = darker(case, 0.25)
		decor(model, "Rim", V(w + 0.3, 0.15, 0.12), C(0, screenY + h / 2 + 0.075, frontZ - 0.06), case, rim)
		decor(model, "Rim", V(w + 0.3, 0.15, 0.12), C(0, screenY - h / 2 - 0.075, frontZ - 0.06), case, rim)
		decor(model, "Rim", V(0.15, h, 0.12), C(w / 2 + 0.075, screenY, frontZ - 0.06), case, rim)
		decor(model, "Rim", V(0.15, h, 0.12), C(-w / 2 - 0.075, screenY, frontZ - 0.06), case, rim)
		for _, x in { w / 2 - 0.15, w / 2 - 0.5 } do
			Builder.CreateCylinder(model, "Knob", 0.12, 0.22, C(x, chin / 2, frontZ - 0.06) * Builder.AxisZ, P.Chrome, DECOR)
		end
		decor(model, "Grille", V(w * 0.45, chin * 0.5, 0.04), C(-w / 4, chin / 2, frontZ - 0.02), P.Rubber)
	end
	if o.antenna then
		-- Rabbit ears on top of the bezel box.
		local z = frontZ + 0.35
		for _, side in { -1, 1 } do
			local a = V(side * 0.2, bezelHeight, z)
			local b = V(side * w * 0.45, bezelHeight + w * 0.55, z + 0.3)
			Builder.CreateCylinderBetween(model, "Antenna", a, b, 0.05, P.Chrome, DECOR)
		end
	end
	if o.screenText then
		Builder.CreateSurfaceText(screen, Enum.NormalId.Front, o.screenText, {
			guiName = "Terminal",
			font = P.Font.Terminal,
			color = P.Neon.Phosphor,
			background = P.Text.ScreenBg,
			pixelsPerStud = 60,
			lightInfluence = 0,
			brightness = 1.3,
			xAlignment = Enum.TextXAlignment.Left,
			strokeColor = P.Neon.PhosphorDim,
			strokeTransparency = 0.7,
			padding = 0.08,
		})
	end
	return Builder.place(model, cf, parent)
end

export type StandOptions = { width: number?, height: number? }

-- Rolling metal TV cart. A TV goes on top at y = height + 0.075.
function Props.CreateTVStand(cf: CFrame, parent: Instance?, options: StandOptions?): Model
	local w = (options and options.width) or 3.2
	local h = (options and options.height) or 2.6
	local model = Builder.newModel("TVStand")
	box(model, "Top", V(w, 0.15, 2.2), C(0, h, 0), P.MetalDark)
	decor(model, "Shelf", V(w - 0.2, 0.1, 2.0), C(0, 0.8, 0), P.MetalDark)
	for _, x in { -(w / 2 - 0.1), w / 2 - 0.1 } do
		for _, z in { -1.0, 1.0 } do
			decor(model, "Leg", V(0.14, h - 0.075, 0.14), C(x, (h - 0.075) / 2, z), P.Metal)
		end
	end
	decor(model, "VCR", V(w * 0.7, 0.35, 1.5), C(0, 1.03, -0.1), P.CaseDark)
	return Builder.place(model, cf, parent)
end

----------------------------------------------------------------------------
-- Lights
----------------------------------------------------------------------------
export type FixtureOptions = {
	kind: ("Fluorescent" | "Industrial")?,
	drop: number?, -- studs from the ceiling attachment (local y = 0) down to the fixture
	light: boolean?, -- include an actual light (keep these few)
	brightness: number?,
	range: number?,
	angle: number?,
	shadows: boolean?,
	color: Color3?,
	name: string?,
}

-- Hanging fixture. The origin is the CEILING attachment point; the fixture
-- hangs `drop` studs below it.
--   Fluorescent: steel housing + Neon part named "Tube" (+ SurfaceLight "Light").
--   Industrial:  enamel dome shade + Neon ball "Bulb" (+ SpotLight "Light").
function Props.CreateLightFixture(cf: CFrame, parent: Instance?, options: FixtureOptions?): Model
	local o: FixtureOptions = options or {}
	local drop = o.drop or 6
	local kind = o.kind or "Fluorescent"
	local model = Builder.newModel(o.name or (if kind == "Fluorescent" then "Fluorescent" else "IndustrialLamp"))

	if kind == "Fluorescent" then
		decor(model, "Housing", V(8, 0.5, 1.6), C(0, -drop + 0.25, 0), P.MetalDark)
		local chainLength = drop - 0.5
		for _, x in { -3.2, 3.2 } do
			decor(model, "Chain", V(0.1, chainLength, 0.1), C(x, -chainLength / 2, 0), P.MetalDark)
		end
		local tube = Builder.CreateNeon(model, "Tube", V(7.4, 0.24, 0.8), C(0, -drop - 0.02, 0), P.Neon.Tube)
		if o.light then
			Builder.AddSurfaceLight(tube, {
				name = "Light",
				color = o.color or P.Light.Fluorescent,
				brightness = o.brightness or 1.3,
				range = o.range or 40,
				angle = o.angle or 115,
				face = Enum.NormalId.Bottom,
				shadows = o.shadows,
			})
		end
	else
		Builder.CreateCylinderBetween(model, "Cable", Vector3.zero, V(0, -drop + 1.0, 0), 0.12, P.Rubber, DECOR)
		Builder.CreatePost(model, "Cap", V(0, -drop + 0.4, 0), 0.6, 0.7, P.MetalDark, DECOR)
		Builder.CreatePost(model, "Shade", V(0, -drop + 0.1, 0), 0.35, 3.0, P.MetalOxidised, DECOR)
		Builder.CreatePost(model, "ShadeInner", V(0, -drop + 0.08, 0), 0.04, 2.6, P.CharcoalDeep, DECOR)
		local bulbSwatch: Swatch = { Color = P.Neon.Bulb, Material = Enum.Material.Neon }
		local bulb = Builder.CreateBall(model, "Bulb", 0.7, C(0, -drop - 0.15, 0), bulbSwatch, DECOR)
		if o.light then
			Builder.AddSpotLight(bulb, {
				name = "Light",
				color = o.color or P.Light.Warm,
				brightness = o.brightness or 2,
				range = o.range or 34,
				angle = o.angle or 100,
				face = Enum.NormalId.Bottom,
				shadows = o.shadows,
			})
		end
	end
	return Builder.place(model, cf, parent)
end

export type DeskLampOptions = { light: boolean?, shadows: boolean? }

-- Green-shaded banker's lamp. Sits on y = 0.
function Props.CreateDeskLamp(cf: CFrame, parent: Instance?, options: DeskLampOptions?): Model
	local model = Builder.newModel("DeskLamp")
	Builder.CreatePost(model, "Base", Vector3.zero, 0.12, 0.6, P.Brass, DECOR)
	Builder.CreatePost(model, "Stem", V(0, 0.12, 0.1), 0.85, 0.08, P.Brass, DECOR)
	decor(model, "Shade", V(1.1, 0.3, 0.5), C(0, 1.08, -0.05), P.GreenDeep, { decor = true, reflectance = 0.15 })
	local bulb = Builder.CreateNeon(model, "Bulb", V(0.8, 0.06, 0.3), C(0, 0.9, -0.05), P.Neon.Bulb)
	if options and options.light then
		Builder.AddPointLight(bulb, {
			name = "Light",
			color = P.Light.Warm,
			brightness = 1.2,
			range = 12,
			shadows = options.shadows,
		})
	end
	return Builder.place(model, cf, parent)
end

----------------------------------------------------------------------------
-- Wall furniture
----------------------------------------------------------------------------
export type ClockOptions = { diameter: number?, hour: number?, minute: number? }

-- Institutional wall clock (wall-mounted; -Z points into the room).
function Props.CreateWallClock(cf: CFrame, parent: Instance?, options: ClockOptions?): Model
	local o: ClockOptions = options or {}
	local diameter = o.diameter or 2.2
	local hour, minute = o.hour or 11, o.minute or 58
	local model = Builder.newModel("WallClock")
	local axis = Builder.AxisZ

	Builder.CreateCylinder(model, "Rim", 0.3, diameter, C(0, 0, -0.15) * axis, P.MetalDark, DECOR)
	Builder.CreateCylinder(model, "Face", 0.04, diameter - 0.3, C(0, 0, -0.32) * axis, P.Paper, DECOR)

	-- Angles are clockwise as seen by someone facing the clock; a part rotated
	-- by CFrame.Angles(0, 0, a) has its local Y pointing at (-sin a, cos a).
	local function radial(angle: number, distance: number, z: number): CFrame
		return C(-math.sin(angle) * distance, math.cos(angle) * distance, z) * CFrame.Angles(0, 0, angle)
	end
	for quarter = 0, 3 do
		decor(model, "Tick", V(0.12, 0.3, 0.03), radial(quarter * math.pi / 2, diameter / 2 - 0.4, -0.355), P.Rubber)
	end
	local hourAngle = ((hour % 12) + minute / 60) / 12 * 2 * math.pi
	local minuteAngle = minute / 60 * 2 * math.pi
	local hourLength, minuteLength = diameter * 0.25, diameter * 0.38
	decor(model, "HourHand", V(0.14, hourLength, 0.03), radial(hourAngle, hourLength / 2, -0.37), P.Rubber)
	decor(model, "MinuteHand", V(0.09, minuteLength, 0.03), radial(minuteAngle, minuteLength / 2, -0.4), P.Rubber)
	Builder.CreateCylinder(model, "Pin", 0.06, 0.16, C(0, 0, -0.43) * axis, P.RedDesat, DECOR)
	return Builder.place(model, cf, parent)
end

export type VentOptions = { width: number?, height: number? }

-- Louvred air vent (wall or ceiling; -Z points out of the surface).
function Props.CreateVent(cf: CFrame, parent: Instance?, options: VentOptions?): Model
	local w = (options and options.width) or 3
	local h = (options and options.height) or 2
	local model = Builder.newModel("Vent")
	decor(model, "Frame", V(w + 0.3, h + 0.3, 0.12), C(0, 0, -0.08), P.MetalDark)
	decor(model, "Duct", V(w, h, 0.02), C(0, 0, -0.15), P.CharcoalDeep)
	local slats = math.max(3, math.floor(h / 0.4))
	for index = 1, slats do
		local y = -h / 2 + (index - 0.5) * h / slats
		decor(model, "Slat", V(w, 0.08, h / slats * 1.1), C(0, y, -0.25) * CFrame.Angles(math.rad(-35), 0, 0), P.Metal)
	end
	return Builder.place(model, cf, parent)
end

-- CCTV camera on a wall arm, aimed at the world-space `target`.
function Props.CreateSecurityCamera(mount: CFrame, target: Vector3, parent: Instance?): Model
	local model = Builder.newModel("SecurityCamera")
	decor(model, "Mount", V(0.6, 0.8, 0.1), C(0, 0, -0.05), P.MetalDark)
	local armEnd = V(0, 0, -0.9)
	Builder.CreateCylinderBetween(model, "Arm", V(0, 0, -0.1), armEnd, 0.16, P.MetalDark, DECOR)
	local localTarget = mount:PointToObjectSpace(target)
	local aim = Builder.facing(armEnd, localTarget - armEnd)
	decor(model, "Body", V(0.55, 0.5, 1.3), aim * C(0, -0.32, -0.45), P.CaseBeige)
	decor(model, "Hood", V(0.7, 0.1, 1.55), aim * C(0, -0.02, -0.55), P.MetalDark)
	Builder.CreateCylinder(model, "Lens", 0.12, 0.34, aim * C(0, -0.32, -1.15) * Builder.AxisZ, P.GlassDark, {
		decor = true,
		reflectance = 0.3,
	})
	Builder.CreateNeon(model, "Led", V(0.08, 0.08, 0.04), aim * C(0.18, -0.15, -1.11), P.Neon.StatusRed)
	return Builder.place(model, mount, parent)
end

export type SignOptions = {
	width: number,
	height: number,
	depth: number?,
	text: string,
	subtext: string?,
	font: Enum.Font?,
	color: Color3?,
	plate: Swatch?,
	frame: Swatch?,
	pixelsPerStud: number?,
	brightness: number?,
	lightInfluence: number?,
	twoSided: boolean?, -- hanging signs: text on both faces
	name: string?,
}

local function signGui(plate: BasePart, face: Enum.NormalId, o: SignOptions)
	local gui = Instance.new("SurfaceGui")
	gui.Name = "SignGui"
	gui.Face = face
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = o.pixelsPerStud or 24
	gui.LightInfluence = o.lightInfluence or 0.3
	gui.Brightness = o.brightness or 1.2
	gui.ClipsDescendants = true

	local function line(name: string, text: string, top: number, height: number, font: Enum.Font, color: Color3)
		local label = Instance.new("TextLabel")
		label.Name = name
		label.BackgroundTransparency = 1
		label.Position = UDim2.fromScale(0.04, top)
		label.Size = UDim2.fromScale(0.92, height)
		label.FontFace = Font.fromEnum(font)
		label.Text = text
		label.TextScaled = true
		label.TextColor3 = color
		label.TextStrokeTransparency = 0.8
		label.Parent = gui
	end
	local font = o.font or P.Font.Sign
	local color = o.color or P.Text.Cream
	if o.subtext then
		line("Title", o.text, 0.08, 0.58, font, color)
		line("Subtitle", o.subtext, 0.7, 0.22, font, color:Lerp(Color3.new(0, 0, 0), 0.3))
	else
		line("Title", o.text, 0.1, 0.8, font, color)
	end
	gui.Parent = plate
end

-- Framed sign plate (wall-mounted; -Z points into the room).
function Props.CreateSign(cf: CFrame, parent: Instance?, o: SignOptions): Model
	local depth = o.depth or 0.3
	local model = Builder.newModel(o.name or "Sign")
	decor(model, "Frame", V(o.width + 0.3, o.height + 0.3, depth), C(0, 0, -depth / 2 - 0.02), o.frame or P.Brass)
	local plate = decor(model, "Plate", V(o.width, o.height, 0.06), C(0, 0, -depth - 0.04), o.plate or P.CharcoalDeep)
	signGui(plate, Enum.NormalId.Front, o)
	if o.twoSided then
		-- The back of a hanging sign: a second plate behind the frame.
		local back = decor(model, "PlateBack", V(o.width, o.height, 0.06), C(0, 0, 0.01), o.plate or P.CharcoalDeep)
		signGui(back, Enum.NormalId.Back, o)
	end
	return Builder.place(model, cf, parent)
end

export type BoardOptions = { width: number?, height: number?, seed: number?, title: string? }

-- Cork case board with pinned papers and red string (wall-mounted).
function Props.CreateNoticeBoard(cf: CFrame, parent: Instance?, options: BoardOptions?): Model
	local o: BoardOptions = options or {}
	local w, h = o.width or 6, o.height or 4
	local rng = Random.new(o.seed or 3)
	local model = Builder.newModel("CaseBoard")
	decor(model, "Frame", V(w + 0.3, h + 0.3, 0.15), C(0, 0, -0.095), P.WoodDark)
	decor(model, "Cork", V(w, h, 0.06), C(0, 0, -0.2), P.Cork)
	local tints = { P.Paper, P.PaperOld, P.Manila, P.Paper }
	local pins: { Vector3 } = {}
	for index = 1, 5 do
		local pw, ph = rng:NextNumber(0.8, 1.4), rng:NextNumber(1.0, 1.6)
		local x = rng:NextNumber(-w / 2 + pw / 2 + 0.2, w / 2 - pw / 2 - 0.2)
		local y = rng:NextNumber(-h / 2 + ph / 2 + 0.2, h / 2 - ph / 2 - 0.2)
		local z = -0.24 - index * 0.004 -- stagger depth so overlapping sheets never z-fight
		decor(model, "Paper", V(pw, ph, 0.02), C(x, y, z) * CFrame.Angles(0, 0, math.rad(rng:NextNumber(-8, 8))), tints[(index % #tints) + 1])
		table.insert(pins, V(x, y + ph / 2 - 0.15, -0.28))
	end
	for index = 1, 3, 2 do
		Builder.CreateCylinderBetween(model, "String", pins[index], pins[index + 1], 0.04, P.RedDesat, DECOR)
	end
	if o.title then
		local plaque = decor(model, "Plaque", V(w * 0.5, 0.5, 0.08), C(0, h / 2 + 0.5, -0.06), P.Brass)
		Builder.CreateSurfaceText(plaque, Enum.NormalId.Front, o.title, {
			font = P.Font.Plaque,
			color = P.Text.Ink,
			pixelsPerStud = 40,
			lightInfluence = 1,
		})
	end
	return Builder.place(model, cf, parent)
end

export type DoorOptions = {
	width: number?,
	height: number?,
	kind: ("Metal" | "Wood" | "Office")?,
	slabName: string?,
	label: string?,
	window: boolean?,
}

-- Door mounted on a wall face (origin = bottom centre on the wall surface,
-- -Z into the room). The slab is a single part named `slabName` (default
-- "Slab") so a caller can re-parent it (e.g. Names.RoomDoor).
function Props.CreateDoor(cf: CFrame, parent: Instance?, options: DoorOptions?): Model
	local o: DoorOptions = options or {}
	local w, h = o.width or 4, o.height or 8.6
	local kind = o.kind or "Metal"
	local slabSwatch = if kind == "Metal" then P.MetalOxidised elseif kind == "Wood" then P.WoodDark else P.Wood
	local frameSwatch = if kind == "Metal" then P.MetalDark else P.WoodDark
	local model = Builder.newModel("Door")

	box(model, o.slabName or "Slab", V(w, h, 0.35), C(0, 0.02 + h / 2, -0.195), slabSwatch)
	for _, side in { -1, 1 } do
		decor(model, "Jamb", V(0.5, h + 0.02, 0.5), C(side * (w / 2 + 0.25), (h + 0.02) / 2, -0.27), frameSwatch, NO_SHADOW)
	end
	decor(model, "Head", V(w + 1, 0.5, 0.5), C(0, h + 0.27, -0.27), frameSwatch, NO_SHADOW)

	local handleX = -(w / 2 - 0.45)
	decor(model, "HandleBase", V(0.2, 0.55, 0.06), C(handleX, h * 0.45, -0.4), P.Chrome)
	decor(model, "Handle", V(0.6, 0.1, 0.12), C(handleX + 0.22, h * 0.45 + 0.1, -0.49), P.Chrome)
	for _, y in { h * 0.18, h * 0.82 } do
		Builder.CreatePost(model, "Hinge", V(w / 2 - 0.05, y - 0.3, -0.38), 0.6, 0.18, P.MetalDark, DECOR)
	end

	if kind == "Metal" then
		decor(model, "KickPlate", V(w - 0.4, 0.9, 0.04), C(0, 0.55, -0.39), P.DiamondPlate)
		decor(model, "Rivets", V(w - 0.3, 0.12, 0.05), C(0, h * 0.6, -0.39), P.MetalDark)
	end
	if o.window or kind == "Office" then
		if kind == "Office" then
			local pane = decor(model, "Pane", V(w - 0.8, h * 0.35, 0.04), C(0, h * 0.68, -0.39), P.GlassFrosted)
			Builder.CreateSurfaceText(pane, Enum.NormalId.Front, o.label or "PRIVATE", {
				font = P.Font.Sign,
				color = P.Text.Ink,
				pixelsPerStud = 30,
				lightInfluence = 0.2,
				brightness = 1.1,
				padding = 0.18,
			})
		else
			decor(model, "WiredGlass", V(1.0, 1.4, 0.04), C(0, h * 0.72, -0.39), P.GlassWired, {
				decor = true,
				reflectance = 0.25,
			})
		end
	end
	if o.label and kind ~= "Office" then
		local plate = decor(model, "NamePlate", V(1.8, 0.45, 0.04), C(0, h * 0.55, -0.39), P.Brass)
		Builder.CreateSurfaceText(plate, Enum.NormalId.Front, o.label, {
			font = P.Font.Plaque,
			color = P.Text.Ink,
			pixelsPerStud = 40,
			lightInfluence = 1,
		})
	end
	return Builder.place(model, cf, parent)
end

export type RailingOptions = { length: number, height: number?, spacing: number?, swatch: Swatch? }

-- Free-standing guard rail running along local X, centred on the origin.
-- Posts and rails collide so people keep their distance.
function Props.CreateRailing(cf: CFrame, parent: Instance?, o: RailingOptions): Model
	local height = o.height or 3.6
	local spacing = o.spacing or 4.5
	local steel = o.swatch or P.MetalDark
	local model = Builder.newModel("Railing")
	local posts = math.max(1, math.floor(o.length / spacing + 0.5))
	for index = 0, posts do
		local x = -o.length / 2 + index * o.length / posts
		box(model, "Post", V(0.22, height, 0.22), C(x, height / 2, 0), steel, NO_SHADOW)
	end
	Builder.CreateCylinder(model, "TopRail", o.length + 0.3, 0.24, C(0, height, 0), steel, NO_SHADOW)
	Builder.CreateCylinder(model, "MidRail", o.length, 0.14, C(0, height * 0.5, 0), steel, NO_SHADOW)
	return Builder.place(model, cf, parent)
end

----------------------------------------------------------------------------
-- Pipes
----------------------------------------------------------------------------
export type PipeOptions = { diameter: number?, swatch: Swatch?, clampEvery: number?, collide: boolean? }

-- Exposed pipe through `points` (in `origin`'s local space): straight
-- cylinders, ball elbows at bends, flanges at both ends, clamps along runs.
function Props.CreatePipeRun(origin: CFrame, points: { Vector3 }, parent: Instance?, options: PipeOptions?): Model
	local o: PipeOptions = options or {}
	local diameter = o.diameter or 0.6
	local steel = o.swatch or P.MetalOxidised
	local clampEvery = o.clampEvery or 9
	local collide = o.collide == true
	local flags: PartFlags = { shadow = false, collide = collide, query = collide }
	local model = Builder.newModel("PipeRun")

	for index = 1, #points - 1 do
		local a, b = points[index], points[index + 1]
		Builder.CreateCylinderBetween(model, "Pipe", a, b, diameter, steel, flags)
		local delta = b - a
		local length = delta.Magnitude
		local direction = delta.Unit
		local clamps = math.floor(length / clampEvery)
		for clamp = 1, clamps do
			local at = a + direction * (clamp * length / (clamps + 1))
			Builder.CreateCylinderBetween(model, "Clamp", at - direction * 0.12, at + direction * 0.12, diameter * 1.3, P.MetalDark, DECOR)
		end
		if index > 1 then
			Builder.CreateBall(model, "Elbow", diameter * 1.25, C(a), steel, DECOR)
		end
	end
	for _, pair in { { 1, 2 }, { #points, #points - 1 } } do
		local endPoint, inward = points[pair[1]], points[pair[2]]
		local direction = (inward - endPoint).Unit
		Builder.CreateCylinderBetween(model, "Flange", endPoint, endPoint + direction * 0.2, diameter * 1.6, P.MetalDark, DECOR)
	end
	return Builder.place(model, origin, parent)
end

----------------------------------------------------------------------------
-- Small clutter
----------------------------------------------------------------------------
export type PaperOptions = { seed: number?, sheets: number?, folder: boolean? }

-- A loose stack of case papers (sits on y = 0).
function Props.CreatePaperStack(cf: CFrame, parent: Instance?, options: PaperOptions?): Model
	local o: PaperOptions = options or {}
	local rng = Random.new(o.seed or 1)
	local model = Builder.newModel("Papers")
	local sheets = o.sheets or 3
	for index = 1, sheets do
		local yaw = math.rad(rng:NextNumber(-14, 14))
		local offset = V(rng:NextNumber(-0.1, 0.1), 0.012 + (index - 1) * 0.03, rng:NextNumber(-0.1, 0.1))
		local tint = if rng:NextNumber() < 0.5 then P.Paper else P.PaperOld
		decor(model, "Sheet", V(0.85, 0.02, 1.1), C(offset) * CFrame.Angles(0, yaw, 0), tint)
	end
	if o.folder then
		local y = 0.012 + sheets * 0.03 + 0.01
		decor(model, "Folder", V(1.0, 0.04, 1.25), C(0.05, y, 0) * CFrame.Angles(0, math.rad(rng:NextNumber(-8, 8)), 0), P.Manila)
	end
	return Builder.place(model, cf, parent)
end

-- Rotary desk telephone (sits on y = 0).
function Props.CreateTelephone(cf: CFrame, parent: Instance?): Model
	local model = Builder.newModel("Telephone")
	decor(model, "Body", V(0.7, 0.28, 0.8), C(0, 0.14, 0), P.Rubber)
	Builder.CreatePost(model, "Dial", V(0, 0.28, -0.12), 0.03, 0.42, P.Chrome, DECOR)
	decor(model, "Handset", V(1.0, 0.14, 0.22), C(0, 0.37, 0.15), P.Rubber)
	return Builder.place(model, cf, parent)
end

-- Interview microphone on a short stand (sits on y = 0, points -Z).
function Props.CreateMicrophone(cf: CFrame, parent: Instance?): Model
	local model = Builder.newModel("Microphone")
	Builder.CreatePost(model, "Base", Vector3.zero, 0.08, 0.5, P.MetalDark, DECOR)
	Builder.CreateCylinderBetween(model, "Stem", V(0, 0.08, 0), V(0, 0.6, -0.15), 0.06, P.Chrome, DECOR)
	Builder.CreateBall(model, "Head", 0.24, C(0, 0.66, -0.19), P.MetalDark, DECOR)
	return Builder.place(model, cf, parent)
end

-- Reel-to-reel tape recorder on a rolling cart (front -Z).
function Props.CreateRecorder(cf: CFrame, parent: Instance?): Model
	local model = Builder.newModel("Recorder")
	local top = 3.0
	box(model, "CartTop", V(2.6, 0.12, 1.8), C(0, top - 0.06, 0), P.MetalDark)
	decor(model, "CartShelf", V(2.4, 0.1, 1.6), C(0, 0.9, 0), P.MetalDark)
	local postHeight = top - 0.47
	for _, x in { -1.2, 1.2 } do
		for _, z in { -0.8, 0.8 } do
			decor(model, "Post", V(0.12, postHeight, 0.12), C(x, 0.35 + postHeight / 2, z), P.Metal)
			Builder.CreateBall(model, "Caster", 0.3, C(x, 0.15, z), P.Rubber, DECOR)
		end
	end
	box(model, "Deck", V(2.2, 1.9, 0.8), C(0, top + 0.95, 0.2), P.CaseDark)
	for _, x in { -0.5, 0.5 } do
		Builder.CreateCylinder(model, "Reel", 0.06, 0.85, C(x, top + 1.35, -0.23) * Builder.AxisZ, P.Metal, DECOR)
		Builder.CreateCylinder(model, "Hub", 0.06, 0.22, C(x, top + 1.35, -0.29) * Builder.AxisZ, P.Rubber, DECOR)
	end
	decor(model, "Tape", V(1.0, 0.05, 0.03), C(0, top + 0.95, -0.22), P.Rubber)
	Builder.CreateNeon(model, "Meter", V(0.5, 0.22, 0.04), C(-0.55, top + 0.45, -0.21), P.Neon.AmberDim)
	Builder.CreateNeon(model, "RecLamp", V(0.14, 0.14, 0.04), C(0.8, top + 0.45, -0.21), P.Neon.StatusRed)
	decor(model, "Keys", V(0.9, 0.12, 0.06), C(0.15, top + 0.3, -0.22), P.Chrome)
	decor(model, "TapeBox", V(0.9, 0.3, 0.9), C(-0.5, 1.1, 0), P.Cardboard)
	decor(model, "TapeBox", V(0.9, 0.3, 0.9), C(0.55, 1.1, 0.1) * CFrame.Angles(0, math.rad(12), 0), P.Manila)
	return Builder.place(model, cf, parent)
end

-- Office water cooler (sits on y = 0).
function Props.CreateWaterCooler(cf: CFrame, parent: Instance?): Model
	local model = Builder.newModel("WaterCooler")
	box(model, "Cabinet", V(1.3, 3.0, 1.3), C(0, 1.5, 0), P.CaseBeige)
	Builder.CreatePost(model, "Jug", V(0, 3.0, 0), 1.5, 1.1, P.GlassDark, { decor = true, transparency = 0.35 })
	Builder.CreatePost(model, "Neck", V(0, 4.5, 0), 0.25, 0.45, P.GlassDark, { decor = true, transparency = 0.35 })
	decor(model, "Tap", V(0.18, 0.18, 0.2), C(-0.25, 2.3, -0.72), P.RedDesat)
	decor(model, "Tap", V(0.18, 0.18, 0.2), C(0.25, 2.3, -0.72), P.Chrome)
	return Builder.place(model, cf, parent)
end

-- Steel waste bin (sits on y = 0).
function Props.CreateTrashBin(cf: CFrame, parent: Instance?): Model
	local model = Builder.newModel("TrashBin")
	Builder.CreatePost(model, "Bin", Vector3.zero, 1.4, 1.0, P.MetalDark, DECOR)
	Builder.CreatePost(model, "Rim", V(0, 1.4, 0), 0.08, 1.08, P.Metal, DECOR)
	Builder.CreateBall(model, "Crumple", 0.45, C(0.15, 1.45, 0.1), P.Paper, DECOR)
	return Builder.place(model, cf, parent)
end

-- Dead potted plant (sits on y = 0).
function Props.CreatePlant(cf: CFrame, parent: Instance?, seed: number?): Model
	local model = Builder.newModel("Plant")
	local rng = Random.new(seed or 11)
	Builder.CreatePost(model, "Pot", Vector3.zero, 1.4, 1.3, P.RedDark, DECOR)
	Builder.CreatePost(model, "Soil", V(0, 1.4, 0), 0.04, 1.15, P.Soil, DECOR)
	for index = 1, 3 do
		local angle = index * 2 * math.pi / 3 + rng:NextNumber(-0.4, 0.4)
		local tip = V(math.cos(angle) * 0.9, 1.4 + rng:NextNumber(1.6, 2.6), math.sin(angle) * 0.9)
		Builder.CreateCylinderBetween(model, "Stalk", V(0, 1.42, 0), tip, 0.07, P.DeadLeaf, DECOR)
		if index ~= 2 then
			decor(model, "Leaf", V(0.08, 0.5, 0.9), C(tip) * CFrame.Angles(rng:NextNumber(-0.8, 0.8), angle, 0.6), P.DeadLeaf)
		end
	end
	return Builder.place(model, cf, parent)
end

-- Coat rack with a detective's trench coat and fedora (sits on y = 0).
function Props.CreateCoatRack(cf: CFrame, parent: Instance?): Model
	local model = Builder.newModel("CoatRack")
	Builder.CreatePost(model, "Base", Vector3.zero, 0.15, 1.3, P.WoodDark, DECOR)
	Builder.CreatePost(model, "Pole", V(0, 0.15, 0), 5.6, 0.18, P.WoodDark)
	for index = 0, 2 do
		local angle = index * 2 * math.pi / 3
		local tip = V(math.cos(angle) * 0.55, 5.6, math.sin(angle) * 0.55)
		Builder.CreateCylinderBetween(model, "Hook", V(0, 5.3, 0), tip, 0.08, P.Brass, DECOR)
	end
	decor(model, "Coat", V(1.3, 3.2, 0.55), C(0.45, 3.85, 0) * CFrame.Angles(0, 0, math.rad(-6)), P.FabricCharcoal)
	decor(model, "Collar", V(1.1, 0.4, 0.7), C(0.5, 5.4, 0), P.FabricCharcoal)
	local hatAt = C(-0.55 * 0.5, 5.75, -0.55 * 0.87)
	Builder.CreateCylinder(model, "HatBrim", 0.06, 1.1, hatAt * Builder.AxisY, P.CharcoalDeep, DECOR)
	Builder.CreateCylinder(model, "HatCrown", 0.4, 0.62, (hatAt + V(0, 0.2, 0)) * Builder.AxisY, P.CharcoalDeep, DECOR)
	return Builder.place(model, cf, parent)
end

return Props
