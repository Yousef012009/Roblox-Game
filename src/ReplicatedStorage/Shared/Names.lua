--!strict
--[[
	Names  (ModuleScript)  ·  ReplicatedStorage/Shared/Names

	THE NAMING CONTRACT. The map generator creates objects with exactly these
	names; GameManager and ClientManager look them up with exactly these
	names. Never type one of these strings anywhere else; always go through
	this module.

	Workspace
	├── Map                                   (Folder)   attribute MapReady = true when built
	│   ├── Lobby                             (Model)
	│   │   ├── LobbySpawn                    (SpawnLocation)
	│   │   ├── LobbyReturnPoints             (Folder)   Parts: where players land after a match
	│   │   ├── Fluorescents                  (Folder)   flickering light fixtures (client FX)
	│   │   ├── CRTs                          (Folder)   static TVs (client FX); each has a "Screen" part
	│   │   └── RainEmitters                  (Folder)   window rain (ParticleEmitters)
	│   └── Queues                            (Folder)
	│       └── Queue01 … Queue04             (Model)    attributes: QueueIndex, DoorsOpen, Count, State
	│           ├── Queue01_Trigger           (Part)     invisible detection volume (server spatial check)
	│           ├── Queue01_Exit              (Part)     where players are placed when removed from the queue
	│           ├── Queue01_Spot1 … _Spot8    (Part)     floor markings / arrival points
	│           ├── Queue01_Display           (Part)     SurfaceGui "DisplayGui" > TextLabel "Count" ("2/4")
	│           ├── Queue01_LightRed          (Part)     neon status light
	│           ├── Queue01_LightGreen        (Part)
	│           ├── Queue01_DoorLeft / _DoorRight (Part) slide open/closed (client tween from DoorsOpen)
	│           └── Queue01_DoorBlocker       (Part)     invisible; server enables collision while departing
	└── ActiveMatches                         (Folder)   live cloned rooms: "Match_<slot>"

	ServerStorage
	└── InterrogationModuleTemplate           (Model)    PrimaryPart = ModuleRoot, pivot at the module origin
	    ├── ModuleRoot                        (Part)     invisible; Model pivot = room centre on the floor
	    ├── Seats                             (Folder)   SeatAnchor01 … SeatAnchor08 (Seat), clockwise from above
	    ├── TVScreen                          (Part)     Front face → room; SurfaceGui "TVGui"
	    │       TVGui > Screen (Frame) > Header, Category, Speaker, Answer, Footer (TextLabels), Static (Frame)
	    ├── BulbPivot                         (Part)     invisible, at the ceiling; the swing hinge
	    ├── BulbAssembly                      (Model)    PrimaryPart "Bulb"; Cable, Socket, Bulb (PointLight "BulbLight")
	    ├── TwoWayMirror                      (Part)     restyled locally per client
	    ├── RoomLights                        (Folder)   lights the client tints red on elimination
	    ├── SpectatorSpawns                   (Folder)   SpectatorSpawn01 … SpectatorSpawn08 (Part)
	    ├── CameraAnchors                     (Folder)   IntroCamera, InterrogationCamera, CallerCamera,
	    │                                                SpectatorCamera, SpectatorCamera02, SpectatorCamera03, VictoryCamera
	    └── RoomDoor                          (Part)     heavy metal door (decor + entry point)
]]

local Names = {}

-- Top level ----------------------------------------------------------------
Names.Map = "Map"
Names.Lobby = "Lobby"
Names.Queues = "Queues"
Names.ActiveMatches = "ActiveMatches"
Names.Template = "InterrogationModuleTemplate"
Names.MapReadyAttribute = "MapReady"
Names.MapVersionAttribute = "MapVersion"

-- Lobby --------------------------------------------------------------------
Names.LobbySpawn = "LobbySpawn"
Names.LobbyReturnPoints = "LobbyReturnPoints"
Names.Fluorescents = "Fluorescents"
Names.CRTs = "CRTs"
Names.CRTScreen = "Screen"
Names.RainEmitters = "RainEmitters"

-- Queues -------------------------------------------------------------------
function Names.Queue(index: number): string
	return string.format("Queue%02d", index)
end
function Names.QueueTrigger(index: number): string
	return Names.Queue(index) .. "_Trigger"
end
function Names.QueueExit(index: number): string
	return Names.Queue(index) .. "_Exit"
end
function Names.QueueSpot(index: number, spot: number): string
	return Names.Queue(index) .. "_Spot" .. spot
end
function Names.QueueDisplay(index: number): string
	return Names.Queue(index) .. "_Display"
end
function Names.QueueLightRed(index: number): string
	return Names.Queue(index) .. "_LightRed"
end
function Names.QueueLightGreen(index: number): string
	return Names.Queue(index) .. "_LightGreen"
end
function Names.QueueDoorLeft(index: number): string
	return Names.Queue(index) .. "_DoorLeft"
end
function Names.QueueDoorRight(index: number): string
	return Names.Queue(index) .. "_DoorRight"
end
function Names.QueueDoorBlocker(index: number): string
	return Names.Queue(index) .. "_DoorBlocker"
end
Names.QueueDisplayGui = "DisplayGui"
Names.QueueDisplayLabel = "Count"
-- Attributes on each QueueNN model (server writes, client reads)
Names.AttrQueueIndex = "QueueIndex"
Names.AttrDoorsOpen = "DoorsOpen"
Names.AttrQueueCount = "Count"
Names.AttrQueueState = "State"
-- Attributes on door parts (generator writes; client tweens between them)
Names.AttrDoorOpenOffset = "OpenOffset" -- Vector3, local-space slide when open

-- Interrogation module -----------------------------------------------------
Names.ModuleRoot = "ModuleRoot"
Names.Seats = "Seats"
function Names.SeatAnchor(seat: number): string
	return string.format("SeatAnchor%02d", seat)
end
Names.TVScreen = "TVScreen"
Names.TVGui = "TVGui"
Names.TVFrame = "Screen"
Names.TVHeader = "Header"
Names.TVCategory = "Category"
Names.TVSpeaker = "Speaker"
Names.TVAnswer = "Answer"
Names.TVFooter = "Footer"
Names.TVStatic = "Static"
Names.BulbPivot = "BulbPivot"
Names.BulbAssembly = "BulbAssembly"
Names.Bulb = "Bulb"
Names.BulbLight = "BulbLight"
Names.TwoWayMirror = "TwoWayMirror"
Names.RoomLights = "RoomLights"
Names.SpectatorSpawns = "SpectatorSpawns"
function Names.SpectatorSpawn(index: number): string
	return string.format("SpectatorSpawn%02d", index)
end
Names.CameraAnchors = "CameraAnchors"
Names.IntroCamera = "IntroCamera"
Names.InterrogationCamera = "InterrogationCamera"
Names.CallerCamera = "CallerCamera"
Names.SpectatorCamera = "SpectatorCamera"
Names.SpectatorCameras = { "SpectatorCamera", "SpectatorCamera02", "SpectatorCamera03" }
Names.VictoryCamera = "VictoryCamera"
Names.RoomDoor = "RoomDoor"
Names.MatchRoomPrefix = "Match_" -- clones are named Match_<slot>

-- Attributes on a cloned room (server writes)
Names.AttrMatchId = "MatchId"
Names.AttrSlot = "Slot"

return Names
