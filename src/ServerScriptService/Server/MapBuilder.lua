--!strict
--[[
	MapBuilder  (ModuleScript)  ·  ServerScriptService/Server/MapBuilder

	Builds a GRAYBOX version of the map with the exact names RoomService
	expects, so you can press Play on an empty Baseplate and test right away.
	It only runs when Workspace has no "InterrogationRoom" (see
	Config.Map.AutoBuildGraybox). Once you build your own stylized map with
	the same names (docs/STUDIO_SETUP.md), this never runs.

	Tip: press Play, then copy Lobby / InterrogationRoom / SpectatorLounge /
	CameraPoints out of the running Workspace and paste them into Edit mode.
	That gives you a correctly named starting point to decorate.

	Layout (top-down, +Z is "south"):

	          ┌──────────── TV wall ────────────┐
	          │            [ TV ]               │
	          │   S1    S2    S3    S4   ← seats face the mirror
	          │   ═════════ table ═════════     │
	          │                    RoomCam ◉    │
	          ├────── [ TWO-WAY MIRROR ] ───────┤
	          │ SpectatorCam ◉   (railing)      │
	          │    spawns · · · · · ·           │
	          │       SPECTATOR LOUNGE          │
	          └─────────────────────────────────┘
]]

local Workspace = game:GetService("Workspace")

local MapBuilder = {}

local ROOM_ORIGIN = Vector3.new(0, 150, 400) -- floor centre of the interrogation room (floats in the sky)
local LOBBY_ORIGIN = Vector3.new(0, 80, -250)

local COLORS = {
	Floor = Color3.fromRGB(92, 70, 54),
	Wall = Color3.fromRGB(104, 120, 108), -- classic interrogation-room green
	Trim = Color3.fromRGB(46, 52, 58),
	Lounge = Color3.fromRGB(34, 38, 50),
	Table = Color3.fromRGB(58, 44, 36),
	Seat = Color3.fromRGB(150, 40, 40),
	Lobby = Color3.fromRGB(196, 170, 128),
	LobbyWall = Color3.fromRGB(70, 52, 44),
}

type PartProps = {
	Name: string,
	Size: Vector3,
	CFrame: CFrame,
	Color: Color3?,
	Material: Enum.Material?,
	Transparency: number?,
	CanCollide: boolean?,
	Parent: Instance,
	ClassName: string?,
	Shape: Enum.PartType?,
}

local function makePart(props: PartProps): BasePart
	local part = Instance.new((props.ClassName or "Part") :: any) :: BasePart
	part.Name = props.Name
	part.Anchored = true
	part.Size = props.Size
	part.CFrame = props.CFrame
	part.Color = props.Color or COLORS.Trim
	part.Material = props.Material or Enum.Material.SmoothPlastic
	part.Transparency = props.Transparency or 0
	part.CanCollide = if props.CanCollide == nil then true else props.CanCollide
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	if props.Shape and part:IsA("Part") then
		part.Shape = props.Shape
	end
	part.Parent = props.Parent
	return part
end

-- Invisible, non-colliding marker part (spawn points, camera points, light emitters).
local function makeMarker(name: string, cframe: CFrame, parent: Instance): BasePart
	local marker = makePart({
		Name = name,
		Size = Vector3.new(1, 1, 1),
		CFrame = cframe,
		Transparency = 1,
		CanCollide = false,
		Parent = parent,
	})
	marker.CanQuery = false
	marker.CanTouch = false
	marker.CastShadow = false
	return marker
end

local function room(x: number, y: number, z: number): Vector3
	return ROOM_ORIGIN + Vector3.new(x, y, z)
end

local function lobby(x: number, y: number, z: number): Vector3
	return LOBBY_ORIGIN + Vector3.new(x, y, z)
end

local function at(position: Vector3): CFrame
	return CFrame.new(position)
end

local function facing(position: Vector3, direction: Vector3): CFrame
	return CFrame.lookAt(position, position + direction)
end

local function sign(parent: Instance, name: string, size: Vector3, cframe: CFrame, text: string)
	local board = makePart({ Name = name, Size = size, CFrame = cframe, Color = COLORS.Trim, Parent = parent })
	local gui = Instance.new("SurfaceGui")
	gui.Face = Enum.NormalId.Front
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 40
	gui.LightInfluence = 0
	gui.Parent = board
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Text = text
	label.TextScaled = true
	label.Font = Enum.Font.SpecialElite
	label.TextColor3 = Color3.fromRGB(255, 196, 61)
	label.Parent = gui
end

----------------------------------------------------------------------------
local function buildInterrogationRoom()
	local model = Instance.new("Model")
	model.Name = "InterrogationRoom"

	local shell = Instance.new("Folder")
	shell.Name = "Shell"
	shell.Parent = model

	-- Floor, ceiling, walls. Interior: x ∈ [-16, 16], z ∈ [-14, 14], height 14.
	makePart({ Name = "Floor", Size = Vector3.new(34, 1, 30), CFrame = at(room(0, -0.5, 0)), Color = COLORS.Floor, Material = Enum.Material.WoodPlanks, Parent = shell })
	makePart({ Name = "Ceiling", Size = Vector3.new(34, 1, 30), CFrame = at(room(0, 14.5, 0)), Color = COLORS.Trim, Parent = shell })
	makePart({ Name = "WallWest", Size = Vector3.new(1, 14, 30), CFrame = at(room(-16.5, 7, 0)), Color = COLORS.Wall, Parent = shell })
	makePart({ Name = "WallEast", Size = Vector3.new(1, 14, 30), CFrame = at(room(16.5, 7, 0)), Color = COLORS.Wall, Parent = shell })
	makePart({ Name = "WallNorth", Size = Vector3.new(34, 14, 1), CFrame = at(room(0, 7, -14.5)), Color = COLORS.Wall, Parent = shell })

	-- South wall, split around the window (x ∈ [-9, 9], y ∈ [3, 11]).
	makePart({ Name = "MirrorWallLeft", Size = Vector3.new(8, 14, 1), CFrame = at(room(-13, 7, 14.5)), Color = COLORS.Wall, Parent = shell })
	makePart({ Name = "MirrorWallRight", Size = Vector3.new(8, 14, 1), CFrame = at(room(13, 7, 14.5)), Color = COLORS.Wall, Parent = shell })
	makePart({ Name = "MirrorWallBottom", Size = Vector3.new(18, 3, 1), CFrame = at(room(0, 1.5, 14.5)), Color = COLORS.Wall, Parent = shell })
	makePart({ Name = "MirrorWallTop", Size = Vector3.new(18, 3, 1), CFrame = at(room(0, 12.5, 14.5)), Color = COLORS.Wall, Parent = shell })

	-- The two-way mirror. Clients restyle it locally: an opaque mirror for
	-- seated players, see-through glass for spectators.
	local mirror = makePart({
		Name = "TwoWayMirror",
		Size = Vector3.new(18, 8, 0.4),
		CFrame = at(room(0, 7, 14.5)),
		Color = Color3.fromRGB(60, 70, 84),
		Material = Enum.Material.Glass,
		Transparency = 0.55,
		Parent = model,
	})
	mirror.Reflectance = 0.1

	-- Table (seats are on its north side, facing the mirror).
	makePart({ Name = "TableTop", Size = Vector3.new(16, 0.6, 4), CFrame = at(room(0, 3.1, -0.8)), Color = COLORS.Table, Material = Enum.Material.Wood, Parent = model })
	for _, offset in { Vector3.new(-7.3, 0, -1.5), Vector3.new(7.3, 0, -1.5), Vector3.new(-7.3, 0, 1.5), Vector3.new(7.3, 0, 1.5) } do
		makePart({ Name = "TableLeg", Size = Vector3.new(0.6, 2.8, 0.6), CFrame = at(room(offset.X, 1.4, -0.8 + offset.Z)), Color = COLORS.Trim, Parent = model })
	end

	-- Seats. Seat N+1 is on Seat N's LEFT (they face +Z), which is the
	-- "I'll go first, to my left" turn order.
	local seats = Instance.new("Folder")
	seats.Name = "Seats"
	seats.Parent = model
	for index, x in { -6, -2, 2, 6 } do
		local seat = makePart({
			Name = `Seat{index}`,
			ClassName = "Seat",
			Size = Vector3.new(2.4, 0.5, 2.4),
			CFrame = facing(room(x, 1.75, -5), Vector3.zAxis),
			Color = COLORS.Seat,
			Material = Enum.Material.Fabric,
			Parent = seats,
		})
		makePart({ Name = "ChairBase", Size = Vector3.new(2.4, 1.5, 2.4), CFrame = at(room(x, 0.75, -5)), Color = COLORS.Trim, Parent = seat })
		makePart({ Name = "ChairBack", Size = Vector3.new(2.4, 3.2, 0.4), CFrame = at(room(x, 3.6, -6.3)), Color = COLORS.Seat, Material = Enum.Material.Fabric, Parent = seat })
	end

	-- TV on the north wall. RoomService adds the SurfaceGui.
	makePart({ Name = "TVBezel", Size = Vector3.new(15, 8.6, 0.4), CFrame = at(room(0, 8.6, -13.8)), Color = Color3.fromRGB(18, 18, 20), Parent = model })
	makePart({ Name = "TVScreen", Size = Vector3.new(14, 7.875, 0.2), CFrame = facing(room(0, 8.6, -13.5), Vector3.zAxis), Color = Color3.fromRGB(8, 10, 14), Parent = model })

	-- Hanging interrogation lamp.
	makePart({ Name = "LampCord", Size = Vector3.new(0.2, 2.2, 0.2), CFrame = at(room(0, 12.9, -0.8)), Color = COLORS.Trim, Parent = model })
	makePart({ Name = "LampShade", Size = Vector3.new(1.2, 3, 3), CFrame = at(room(0, 11.6, -0.8)) * CFrame.Angles(0, 0, math.rad(90)), Color = Color3.fromRGB(40, 70, 52), Material = Enum.Material.Metal, Shape = Enum.PartType.Cylinder, Parent = model })
	local bulb = makePart({ Name = "LampBulb", Size = Vector3.new(0.9, 0.9, 0.9), CFrame = at(room(0, 11, -0.8)), Color = Color3.fromRGB(255, 236, 200), Material = Enum.Material.Neon, Shape = Enum.PartType.Ball, CanCollide = false, Parent = model })
	bulb.CastShadow = false
	local emitter = makeMarker("LampEmitter", at(room(0, 10.4, -0.8)), model)
	local spot = Instance.new("SpotLight")
	spot.Face = Enum.NormalId.Bottom
	spot.Angle = 80
	spot.Brightness = 5
	spot.Range = 22
	spot.Color = Color3.fromRGB(255, 222, 172)
	spot.Shadows = true
	spot.Parent = emitter
	local fill = Instance.new("PointLight")
	fill.Brightness = 0.9
	fill.Range = 30
	fill.Color = Color3.fromRGB(255, 230, 200)
	fill.Parent = emitter

	model.Parent = Workspace
end

----------------------------------------------------------------------------
local function buildSpectatorLounge()
	local model = Instance.new("Model")
	model.Name = "SpectatorLounge"

	-- Interior: z ∈ [15, 32] (behind the mirror wall), darker so the glass reads as a window.
	makePart({ Name = "Floor", Size = Vector3.new(34, 1, 17), CFrame = at(room(0, -0.5, 23.5)), Color = COLORS.Lounge, Material = Enum.Material.Carpet, Parent = model })
	makePart({ Name = "Ceiling", Size = Vector3.new(34, 1, 17), CFrame = at(room(0, 14.5, 23.5)), Color = COLORS.Lounge, Parent = model })
	makePart({ Name = "WallWest", Size = Vector3.new(1, 14, 17), CFrame = at(room(-16.5, 7, 23.5)), Color = COLORS.Lounge, Parent = model })
	makePart({ Name = "WallEast", Size = Vector3.new(1, 14, 17), CFrame = at(room(16.5, 7, 23.5)), Color = COLORS.Lounge, Parent = model })
	makePart({ Name = "WallSouth", Size = Vector3.new(34, 14, 1), CFrame = at(room(0, 7, 32.5)), Color = COLORS.Lounge, Parent = model })

	-- Railing keeps spectators from crowding the glass in front of the camera.
	makePart({ Name = "Railing", Size = Vector3.new(32, 3, 0.5), CFrame = at(room(0, 1.5, 17.5)), Color = COLORS.Trim, Material = Enum.Material.Metal, Parent = model })
	makePart({ Name = "BenchWest", Size = Vector3.new(10, 1.5, 2), CFrame = at(room(-7, 0.75, 27)), Color = COLORS.Trim, Parent = model })
	makePart({ Name = "BenchEast", Size = Vector3.new(10, 1.5, 2), CFrame = at(room(7, 0.75, 27)), Color = COLORS.Trim, Parent = model })

	sign(model, "LoungeSign", Vector3.new(14, 1.6, 0.2), facing(room(0, 12.6, 15.2), Vector3.zAxis), "OBSERVATION ROOM · THEY CAN'T SEE YOU")

	local spawns = Instance.new("Folder")
	spawns.Name = "SpectatorSpawns"
	spawns.Parent = model
	for index, x in { -10, -6, -2, 2, 6, 10 } do
		makeMarker(`Spawn{index}`, facing(room(x, 0.5, 22), -Vector3.zAxis), spawns)
	end

	local emitter = makeMarker("LoungeLight", at(room(0, 13, 25)), model)
	local light = Instance.new("PointLight")
	light.Brightness = 0.6
	light.Range = 26
	light.Color = Color3.fromRGB(120, 140, 210)
	light.Parent = emitter

	model.Parent = Workspace
end

----------------------------------------------------------------------------
local function buildCameraPoints()
	local folder = Instance.new("Folder")
	folder.Name = "CameraPoints"
	local target = room(0, 4.6, -5)
	-- In the room, in front of the mirror, looking at the suspects and the TV behind them.
	makeMarker("RoomCam", CFrame.lookAt(room(0, 10.5, 12.5), target), folder)
	-- In the lounge, looking through the glass.
	makeMarker("SpectatorCam", CFrame.lookAt(room(0, 8.5, 19), target), folder)
	folder.Parent = Workspace
end

----------------------------------------------------------------------------
local function buildLobby()
	local model = Instance.new("Model")
	model.Name = "Lobby"

	makePart({ Name = "Floor", Size = Vector3.new(60, 1, 60), CFrame = at(lobby(0, -0.5, 0)), Color = COLORS.Lobby, Material = Enum.Material.WoodPlanks, Parent = model })
	makePart({ Name = "WallWest", Size = Vector3.new(1, 6, 60), CFrame = at(lobby(-30.5, 3, 0)), Color = COLORS.LobbyWall, Parent = model })
	makePart({ Name = "WallEast", Size = Vector3.new(1, 6, 60), CFrame = at(lobby(30.5, 3, 0)), Color = COLORS.LobbyWall, Parent = model })
	makePart({ Name = "WallNorth", Size = Vector3.new(62, 6, 1), CFrame = at(lobby(0, 3, -30.5)), Color = COLORS.LobbyWall, Parent = model })
	makePart({ Name = "WallSouth", Size = Vector3.new(62, 6, 1), CFrame = at(lobby(0, 3, 30.5)), Color = COLORS.LobbyWall, Parent = model })

	local spawn = Instance.new("SpawnLocation")
	spawn.Name = "LobbySpawn"
	spawn.Anchored = true
	spawn.Size = Vector3.new(8, 1, 8)
	spawn.CFrame = facing(lobby(0, 0.5, 8), -Vector3.zAxis)
	spawn.Neutral = true
	spawn.Duration = 0 -- no spawn force-field
	spawn.Color = COLORS.Trim
	spawn.TopSurface = Enum.SurfaceType.Smooth
	spawn.Parent = model

	-- RoomService adds the status SurfaceGui to this.
	makePart({ Name = "StatusBoard", Size = Vector3.new(20, 10, 0.6), CFrame = facing(lobby(0, 8, -24), Vector3.zAxis), Color = Color3.fromRGB(16, 18, 24), Parent = model })

	model.Parent = Workspace
end

----------------------------------------------------------------------------
function MapBuilder.build()
	warn("[MapBuilder] No InterrogationRoom found: building the graybox map. Set Config.Map.AutoBuildGraybox = false once you have your own.")

	-- A Baseplate template ships with a SpawnLocation. Turn it off so players
	-- always spawn in our lobby.
	for _, descendant in Workspace:GetDescendants() do
		if descendant:IsA("SpawnLocation") then
			descendant.Enabled = false
		end
	end

	buildLobby()
	buildInterrogationRoom()
	buildSpectatorLounge()
	buildCameraPoints()
end

return MapBuilder
