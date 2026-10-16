--!strict
--[[
	MapBuilder  (ModuleScript)  ·  ServerScriptService/MapGen/MapBuilder

	Orchestrates the whole procedural environment:

	  Workspace.Map (Folder)          attributes MapVersion, MapReady
	  ├── Lobby (Model)               Lobby.CreateLobby
	  └── Queues (Folder)
	      └── Queue01 … Queue04       QueueElevator.CreateQueueElevator
	  Workspace.ActiveMatches         ensured (contents never touched)
	  ServerStorage.InterrogationModuleTemplate
	                                  InterrogationModule.CreateModuleTemplate
	  Lighting                        Environment.Apply

	Build(force) is idempotent:
	  • If Workspace.Map carries the current MapVersion and the template is in
	    ServerStorage, nothing is rebuilt; MapReady is (re)set to true.
	  • Otherwise, or when `force` is true, the old Map and template are
	    destroyed and rebuilt.
	  • MapReady = true is written LAST, after the template is in ServerStorage.

	Works in a running game (yields a frame every few hundred parts) and from
	the Studio command bar in Edit mode (never yields), e.g. to bake:
	    require(game.ServerScriptService.MapGen.MapBuilder).Build(true)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local Workspace = game:GetService("Workspace")

local Builder = require(script.Parent.Builder)
local Environment = require(script.Parent.Environment)
local Lobby = require(script.Parent.Lobby)
local QueueElevator = require(script.Parent.QueueElevator)
local InterrogationModule = require(script.Parent.InterrogationModule)
local Names = require(ReplicatedStorage.Shared.Names)
local Config = require(ReplicatedStorage.Shared.Config)

local LOCKED_ATTRIBUTE = "Locked"

local MapBuilder = {}

-- Bump whenever the generator output changes so baked maps are replaced.
MapBuilder.Version = 1

local PARTS_PER_YIELD = 300

local building = false

local function ensureActiveMatches()
	if not Workspace:FindFirstChild(Names.ActiveMatches) then
		Builder.newFolder(Names.ActiveMatches, Workspace)
	end
end

-- The Baseplate template ships a SpawnLocation at the origin that would poke
-- through the lobby floor. Ours lives inside Map.Lobby, never directly under
-- Workspace, so every direct child SpawnLocation is foreign.
local function removeStraySpawns()
	for _, child in Workspace:GetChildren() do
		if child:IsA("SpawnLocation") then
			child:Destroy()
		end
	end
end

local function isCurrent(map: Instance?, template: Instance?): boolean
	return map ~= nil
		and map:IsA("Folder")
		and template ~= nil
		and map:GetAttribute(Names.MapVersionAttribute) == MapBuilder.Version
end

local function buildEverything(): Folder
	assert(#QueueElevator.Layout.CentersX >= Config.Queue.Count, "QueueElevator.Layout has fewer bays than Config.Queue.Count")

	local map = Instance.new("Folder")
	map.Name = Names.Map
	map:SetAttribute(Names.MapVersionAttribute, MapBuilder.Version)
	map:SetAttribute(Names.MapReadyAttribute, false)

	-- Lobby and queues are assembled off-world, then parented in one step.
	Lobby.CreateLobby(map)
	local queues = Builder.newFolder(Names.Queues, map)
	for index = 1, Config.Queue.Count do
		QueueElevator.CreateQueueElevator(index, QueueElevator.PlacementFor(index), queues)
	end
	map.Parent = Workspace

	InterrogationModule.CreateModuleTemplate(ServerStorage)

	map:SetAttribute(Names.MapReadyAttribute, true)
	return map
end

-- Builds (or validates) the environment. Returns Workspace.Map.
function MapBuilder.Build(force: boolean?): Folder
	-- A second caller during a live, yielding build waits for the first.
	while building do
		task.wait()
	end

	Environment.Apply()
	removeStraySpawns()
	ensureActiveMatches()

	local existingMap = Workspace:FindFirstChild(Names.Map)
	local existingTemplate = ServerStorage:FindFirstChild(Names.Template)
	-- A baked map (MapBuilder.Bake) is yours: never regenerate it on Play, even
	-- after a generator update. Only an explicit Build(true) / Bake() replaces it.
	if not force and existingMap and existingTemplate and existingMap:GetAttribute(LOCKED_ATTRIBUTE) == true then
		existingMap:SetAttribute(Names.MapReadyAttribute, true)
		return existingMap :: Folder
	end
	if not force and existingMap and isCurrent(existingMap, existingTemplate) then
		existingMap:SetAttribute(Names.MapReadyAttribute, true)
		return existingMap :: Folder
	end

	building = true
	if existingMap then
		existingMap:Destroy()
	end
	if existingTemplate then
		existingTemplate:Destroy()
	end

	Builder.BeginSession(PARTS_PER_YIELD)
	local started = os.clock()
	local ok, result = pcall(buildEverything)
	building = false
	if not ok then
		error(`[MapBuilder] build failed: {result}`, 0)
	end
	print(`[MapBuilder] map v{MapBuilder.Version} built: {Builder.GetPartCount()} parts in {string.format("%.2f", os.clock() - started)} s`)
	return result
end

--[[
	Bake the map into the place so you can edit it by hand.

	Run ONCE in Studio's Command Bar (View → Command Bar) while NOT playing:

	    require(game.ServerScriptService.MapGen.MapBuilder).Bake()

	Then save the place. Workspace.Map and ServerStorage.InterrogationModuleTemplate
	stay in the file, Play reuses them as they are, and generator updates never
	overwrite them (attribute "Locked" = true). Edit the template in
	ServerStorage to change every interrogation room. Calling Bake() again
	throws away your edits and regenerates.
]]
function MapBuilder.Bake(): Folder
	local map = MapBuilder.Build(true)
	map:SetAttribute(LOCKED_ATTRIBUTE, true)
	print("[MapBuilder] map baked and locked. Save the place (Ctrl+S) to keep it.")
	return map
end

return MapBuilder
