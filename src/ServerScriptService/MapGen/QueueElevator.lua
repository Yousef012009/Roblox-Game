--!strict
--[[
	QueueElevator  (ModuleScript)  ·  ServerScriptService/MapGen/QueueElevator

	One queue chamber: an industrial freight elevator recessed behind the
	lobby's back wall. Built in LOCAL space, then pivoted to `cframe`.

	Local frame (identity rotation = the placement used by the lobby):
	  origin  = centre of the doorway, on the LOBBY-side face of the back wall,
	            at y = 0 (the floor top is y = 0.2 everywhere)
	  +Z      = out of the elevator, into the lobby
	  -Z      = into the chamber

	   lobby side  z = 0  ┌──────── back wall (z ∈ [-1.5, 0]) ────────┐
	                      │   doorway x ∈ [-3.5, 3.5], y ∈ [0.2, 9.2]  │
	   chamber interior   x ∈ [-5.5, 5.5]  z ∈ [-12.5, -1.5]  y ∈ [0.2, 12.2]

	Gameplay parts (Names.lua) are DIRECT children of the QueueNN model; all
	decoration lives in the "Structure", "Interior" and "Portal" folders.
	The lobby builds the back wall itself (with these doorway openings); this
	module builds everything else, including the floor under the doorway so
	the chamber floor meets the lobby floor flush at y = 0.2.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Builder = require(script.Parent.Builder)
local Palette = require(script.Parent.Palette)
local Props = require(script.Parent.Props)
local Names = require(ReplicatedStorage.Shared.Names)
local Config = require(ReplicatedStorage.Shared.Config)

local P = Palette
local V = Vector3.new
local C = CFrame.new
local box = Builder.CreateBox
local decor = Builder.CreateDecor
local DECOR: Builder.PartFlags = table.freeze({ decor = true })

local QueueElevator = {}

-- Shared with Lobby (doorway openings, trim gaps) and MapBuilder (placement).
QueueElevator.Layout = table.freeze({
	CentersX = table.freeze({ -45, -15, 15, 45 }),
	WallZ = -60, -- interior face of the lobby back wall
	WallThickness = 1.5,
	DoorWidth = 7,
	DoorHeight = 9, -- doorway top = FloorTop + DoorHeight = 9.2
	FrameHalfWidth = 4.4, -- outer edge of the door jambs (lobby trim stops here)
	FloorTop = 0.2,
})

local L = QueueElevator.Layout
local FLOOR = L.FloorTop
local WALL_T = L.WallThickness
local DOOR_HALF = L.DoorWidth / 2
local DOOR_TOP = FLOOR + L.DoorHeight
local INNER_HALF = 5.5 -- interior half width (11 wide)
local BACK_Z = -(WALL_T + 11) -- interior back face (11 deep)
local CEILING_Y = FLOOR + 12 -- interior height 12
local CHAMBER_Z = (BACK_Z - WALL_T) / 2 -- centre of the interior along Z (-7)

----------------------------------------------------------------------------
-- Shell
----------------------------------------------------------------------------
local function buildShell(model: Model)
	local folder = Builder.newFolder("Structure", model)
	-- Floor runs under the doorway right up to the lobby floor (z = 0).
	Builder.CreateFloor(folder, "Floor", V(0, FLOOR, (BACK_Z - 1) / 2), INNER_HALF * 2 + 2, -(BACK_Z - 1), P.DiamondPlate)
	local wallHeight = CEILING_Y + 0.8
	local sideLength = -WALL_T - BACK_Z
	for _, side in { -1, 1 } do
		box(folder, "Wall", V(1, wallHeight, sideLength), C(side * (INNER_HALF + 0.5), wallHeight / 2 - 0.8, CHAMBER_Z), P.MetalOxidised)
	end
	box(folder, "Wall", V(INNER_HALF * 2 + 2, wallHeight, 1), C(0, wallHeight / 2 - 0.8, BACK_Z - 0.5), P.MetalOxidised)
	box(folder, "Ceiling", V(INNER_HALF * 2 + 2, 1, -WALL_T - BACK_Z + 1), C(0, CEILING_Y + 0.5, (BACK_Z - 1 - WALL_T) / 2), P.MetalDark)
end

----------------------------------------------------------------------------
-- Interior dressing
----------------------------------------------------------------------------
local function addControlPanelGui(panel: BasePart)
	local gui = Instance.new("SurfaceGui")
	gui.Name = "Buttons"
	gui.Face = Enum.NormalId.Left -- faces -X, into the chamber
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 40
	gui.LightInfluence = 0.3
	gui.Brightness = 1.4
	for row = 0, 3 do
		for column = 0, 1 do
			local button = Instance.new("Frame")
			button.Name = "Button"
			button.AnchorPoint = Vector2.new(0.5, 0.5)
			button.Position = UDim2.fromScale(0.32 + column * 0.36, 0.2 + row * 0.2)
			button.Size = UDim2.fromScale(0.22, 0.11)
			button.BorderSizePixel = 0
			-- the bottom-left button ("B2", the interrogation wing) is lit
			button.BackgroundColor3 = if row == 3 and column == 0 then P.Neon.Amber else P.Rubber.Color
			local corner = Instance.new("UICorner")
			corner.CornerRadius = UDim.new(0.5, 0)
			corner.Parent = button
			button.Parent = gui
		end
	end
	gui.Parent = panel
end

local function buildInterior(model: Model, index: number)
	local folder = Builder.newFolder("Interior", model)
	local innerWidth = INNER_HALF * 2 - 0.04
	local innerDepth = -WALL_T - BACK_Z - 0.1

	-- Diamond-plate kick panels and a faded red stripe on the three walls.
	decor(folder, "KickPlate", V(innerWidth, 1.6, 0.06), C(0, FLOOR + 0.8, BACK_Z + 0.05), P.DiamondPlate)
	decor(folder, "Stripe", V(innerWidth, 0.35, 0.04), C(0, FLOOR + 5.5, BACK_Z + 0.04), P.RedDesat)
	for _, side in { -1, 1 } do
		decor(folder, "KickPlate", V(0.06, 1.6, innerDepth), C(side * (INNER_HALF - 0.05), FLOOR + 0.8, CHAMBER_Z), P.DiamondPlate)
		decor(folder, "Stripe", V(0.04, 0.35, innerDepth), C(side * (INNER_HALF - 0.04), FLOOR + 5.5, CHAMBER_Z), P.RedDesat)
		Builder.CreateCylinder(folder, "Handrail", 8, 0.25, C(side * (INNER_HALF - 0.4), FLOOR + 3.2, CHAMBER_Z - 0.5) * Builder.AxisZ, P.Chrome, DECOR)
		for _, z in { BACK_Z + 2, -WALL_T - 3 } do
			decor(folder, "Bracket", V(0.4, 0.12, 0.12), C(side * (INNER_HALF - 0.2), FLOOR + 3.2, z), P.MetalDark)
		end
	end
	Builder.CreateCylinder(folder, "Handrail", 9, 0.25, C(0, FLOOR + 3.2, BACK_Z + 0.4), P.Chrome, DECOR)
	for _, x in { -3.5, 3.5 } do
		decor(folder, "Bracket", V(0.12, 0.12, 0.4), C(x, FLOOR + 3.2, BACK_Z + 0.2), P.MetalDark)
	end

	-- Dim caged ceiling light: the chamber's only light source.
	decor(folder, "LightFrame", V(4.4, 0.06, 2.9), C(0, CEILING_Y - 0.04, CHAMBER_Z), P.MetalDark)
	local lamp = Builder.CreateNeon(folder, "CeilingLight", V(4, 0.15, 2.5), C(0, CEILING_Y - 0.095, CHAMBER_Z), P.Neon.Tube:Lerp(Color3.new(0, 0, 0), 0.35))
	Builder.AddPointLight(lamp, { name = "Light", color = P.Light.Elevator, brightness = 0.9, range = 14 })

	-- "ELEVATOR N" plaque above the doorway, facing into the chamber.
	local plaque = decor(folder, "Plaque", V(4.2, 0.9, 0.08), C(0, FLOOR + 10.4, -WALL_T - 0.06), P.MetalDark)
	Builder.CreateSurfaceText(plaque, Enum.NormalId.Front, `ELEVATOR {index}  DOWN B2`, {
		font = P.Font.Display,
		color = P.Neon.Amber,
		pixelsPerStud = 40,
		lightInfluence = 0,
		brightness = 1.2,
		padding = 0.12,
	})

	-- Floor-select panel on the right-hand wall by the door.
	local panel = decor(folder, "ControlPanel", V(0.08, 2.6, 1.3), C(INNER_HALF - 0.06, FLOOR + 4.8, -WALL_T - 1.7), P.Chrome)
	addControlPanelGui(panel)
end

----------------------------------------------------------------------------
-- Lobby-side portal: frame, display, status lights, signage
----------------------------------------------------------------------------
local function facingLobby(position: Vector3): CFrame
	return CFrame.lookAt(position, position + Vector3.zAxis)
end

local function buildPortal(model: Model, index: number)
	local folder = Builder.newFolder("Portal", model)
	local jambWidth = L.FrameHalfWidth - DOOR_HALF
	for _, side in { -1, 1 } do
		local x = side * (DOOR_HALF + jambWidth / 2)
		box(folder, "Jamb", V(jambWidth, L.DoorHeight, 0.6), C(x, FLOOR + L.DoorHeight / 2, 0.32), P.MetalDark)
		local hazard = decor(folder, "HazardPlate", V(jambWidth + 0.02, 1.4, 0.04), C(x, FLOOR + 0.7, 0.64), P.Hazard)
		Builder.AddHazardStripes(hazard, Enum.NormalId.Back, 3)
	end
	box(folder, "Header", V(L.FrameHalfWidth * 2, 1.0, 0.6), C(0, DOOR_TOP + 0.5, 0.32), P.MetalDark)

	-- Threshold plate in the doorway and hazard band on the lobby floor.
	decor(folder, "Threshold", V(L.DoorWidth, 0.04, WALL_T), C(0, FLOOR + 0.02, -WALL_T / 2), P.DiamondPlate)
	local strip = decor(folder, "HazardStrip", V(L.DoorWidth + 1.8, 0.04, 0.8), C(0, FLOOR + 0.02, 0.6), P.Hazard)
	Builder.AddHazardStripes(strip, Enum.NormalId.Top, 10)

	-- Call button beside the frame (above the lobby chair rail).
	decor(folder, "CallPanel", V(0.6, 1.0, 0.08), C(L.FrameHalfWidth + 0.7, FLOOR + 5.4, 0.06), P.Chrome)
	Builder.CreateNeon(folder, "CallButton", V(0.25, 0.25, 0.06), C(L.FrameHalfWidth + 0.7, FLOOR + 5.5, 0.12), P.Neon.AmberDim)

	-- Status lights: green = boarding, red = doors shut / departing. Each lamp
	-- keeps its own colour; "lit" is Neon, "dim" is plain plastic (QueueService
	-- toggles Material/Transparency the same way).
	local lights = {
		{ name = Names.QueueLightRed(index), x = -3.2, color = P.Neon.StatusRed, lit = false },
		{ name = Names.QueueLightGreen(index), x = 3.2, color = P.Neon.StatusGreen, lit = true },
	}
	for _, spec in lights do
		decor(folder, "LampHousing", V(1.2, 1.2, 0.2), C(spec.x, FLOOR + 10.9, 0.12), P.MetalDark)
		local material = if spec.lit then Enum.Material.Neon else Enum.Material.SmoothPlastic
		Builder.CreateNeon(model, spec.name, V(0.8, 0.8, 0.3), C(spec.x, FLOOR + 10.9, 0.24), spec.color, { decor = true, material = material })
	end

	-- Counter display above the doors (gameplay part, direct child).
	local display = decor(model, Names.QueueDisplay(index), V(4.6, 1.6, 0.4), facingLobby(V(0, FLOOR + 10.9, 0.24)), P.CharcoalDeep)
	local gui = Instance.new("SurfaceGui")
	gui.Name = Names.QueueDisplayGui
	gui.Face = Enum.NormalId.Front -- the part's Front faces +Z, into the lobby
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 50
	gui.LightInfluence = 0
	gui.Brightness = 1.5
	gui.ClipsDescendants = true
	local label = Instance.new("TextLabel")
	label.Name = Names.QueueDisplayLabel
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundColor3 = P.Text.ScreenBg
	label.BorderSizePixel = 0
	label.FontFace = Font.fromEnum(P.Font.Display)
	label.Text = `0/{Config.Queue.Capacity}`
	label.TextScaled = true
	label.TextColor3 = P.Neon.Amber
	label.TextStrokeColor3 = P.Neon.AmberDim
	label.TextStrokeTransparency = 0.6
	label.Parent = gui
	gui.Parent = display

	-- "QUEUE 0N / ELEVATOR N" sign on the wall above the display.
	Props.CreateSign(facingLobby(V(0, FLOOR + 12.8, 0)), folder, {
		width = 7,
		height = 1.4,
		depth = 0.25,
		text = string.format("QUEUE %02d", index),
		subtext = `ELEVATOR {index}  -  INTERROGATION`,
		font = P.Font.Sign,
		color = P.Text.Cream,
		plate = P.CharcoalDeep,
		frame = P.MetalDark,
		pixelsPerStud = 40,
		brightness = 1.4,
		lightInfluence = 0.2,
		name = "QueueSign",
	})
end

----------------------------------------------------------------------------
-- Gameplay parts
----------------------------------------------------------------------------

-- Paint on the lobby side (+Z = Back face) of a door leaf. A SurfaceGui
-- rides along when the client slides the door, unlike a separate part.
local function addDoorPaint(door: BasePart, stencil: string)
	local gui = Instance.new("SurfaceGui")
	gui.Name = "Paint"
	gui.Face = Enum.NormalId.Back
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 24
	gui.LightInfluence = 1
	gui.ClipsDescendants = true

	local band = Instance.new("Frame")
	band.Name = "Band"
	band.Position = UDim2.fromScale(0, 0.52)
	band.Size = UDim2.fromScale(1, 0.05)
	band.BackgroundColor3 = P.RedDesat.Color
	band.BorderSizePixel = 0
	band.Parent = gui

	local text = Instance.new("TextLabel")
	text.Name = "Stencil"
	text.BackgroundTransparency = 1
	text.Position = UDim2.fromScale(0.1, 0.6)
	text.Size = UDim2.fromScale(0.8, 0.14)
	text.FontFace = Font.fromEnum(P.Font.Sign)
	text.Text = stencil
	text.TextScaled = true
	text.TextColor3 = P.Text.Stencil
	text.TextTransparency = 0.25
	text.Parent = gui
	gui.Parent = door
end

local function buildGameplayParts(model: Model, index: number)
	-- Detection volume: axis-aligned, covers the interior floor, 8 tall.
	Builder.CreateMarker(model, Names.QueueTrigger(index), C(0, FLOOR + 4, CHAMBER_Z), V(10, 8, 10))

	-- Exit marker on the lobby floor, 6 studs out, facing away from the doors.
	Builder.CreateMarker(model, Names.QueueExit(index), facingLobby(V(0, FLOOR + 0.12, 6)), V(2, 0.2, 2))

	-- Standing marks: two rows of four (back row Spot1..4 fills first, then
	-- the front row Spot5..8), inside the trigger, facing the doors.
	local columns = { -3.75, -1.25, 1.25, 3.75 }
	local rows = { CHAMBER_Z - 2.3, CHAMBER_Z + 2.3 }
	assert(#rows * #columns >= Config.Queue.Capacity, "QueueElevator: fewer standing marks than Config.Queue.Capacity")
	for row, z in rows do
		for column, x in columns do
			local spot = (row - 1) * #columns + column
			local cf = facingLobby(V(x, FLOOR + 0.045, z))
			Builder.CreateNeon(model, Names.QueueSpot(index, spot), V(2.1, 0.05, 2.1), cf, P.Neon.FloorMark)
		end
	end

	-- Sliding doors, built CLOSED and staggered in depth so they never
	-- z-fight. OpenOffset (door-local) slides each leaf into the wall pocket.
	local doorBottom = FLOOR + 0.06
	local doorHeight = DOOR_TOP - 0.02 - doorBottom
	local leafWidth = DOOR_HALF + 0.05
	local leaves = {
		{ name = Names.QueueDoorLeft(index), sign = -1, z = -0.85 },
		{ name = Names.QueueDoorRight(index), sign = 1, z = -0.65 },
	}
	for _, leaf in leaves do
		local cf = C(leaf.sign * (leafWidth / 2 - 0.05), doorBottom + doorHeight / 2, leaf.z)
		local door = box(model, leaf.name, V(leafWidth, doorHeight, 0.4), cf, P.Metal, {
			collide = false,
			query = false,
			shadow = true,
		})
		door:SetAttribute(Names.AttrDoorOpenOffset, V(leaf.sign * DOOR_HALF, 0, 0))
		addDoorPaint(door, if leaf.sign < 0 then "Q" else string.format("%02d", index))
	end

	-- Invisible doorway blocker: the server enables collision while departing.
	Builder.CreateMarker(model, Names.QueueDoorBlocker(index), C(0, FLOOR + L.DoorHeight / 2, -WALL_T / 2), V(L.DoorWidth, L.DoorHeight, WALL_T))
end

----------------------------------------------------------------------------
-- Public
----------------------------------------------------------------------------

-- Builds QueueNN at `cframe` (the doorway centre on the lobby wall face,
-- y = 0, facing +Z into the lobby) and parents it to `parent`.
function QueueElevator.CreateQueueElevator(index: number, cframe: CFrame, parent: Instance?): Model
	local model = Builder.newModel(Names.Queue(index))
	buildShell(model)
	buildInterior(model, index)
	buildPortal(model, index)
	buildGameplayParts(model, index)

	model:SetAttribute(Names.AttrQueueIndex, index)
	model:SetAttribute(Names.AttrDoorsOpen, true)
	model:SetAttribute(Names.AttrQueueCount, 0)
	model:SetAttribute(Names.AttrQueueState, "Open")
	return Builder.place(model, cframe, parent)
end

-- World CFrame for queue `index` (1-based) on the lobby back wall.
function QueueElevator.PlacementFor(index: number): CFrame
	return CFrame.new(L.CentersX[index], 0, L.WallZ)
end

return QueueElevator
