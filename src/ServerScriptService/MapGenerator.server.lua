--!strict
--[[
	MapGenerator  (Script)  ·  ServerScriptService/MapGenerator

	Generates the whole Concentration 64 environment with Luau: the detective
	bureau lobby, the four queue elevators, the interrogation room template in
	ServerStorage and the night lighting. No meshes, no imported assets.

	HOW TO USE
	  • Press Play (or start a live server): this script runs and calls
	    MapBuilder.Build(). If the place already contains a baked map of the
	    current version, nothing is rebuilt; it only sets Map.MapReady = true.
	    GameManager waits for that attribute before booting its services.

	  • Bake the map into the place (Studio, EDIT mode, command bar):
	        require(game.ServerScriptService.MapGen.MapBuilder).Build(true)
	    then save. The map, template and Lighting become part of the place
	    file, so servers start faster and you can inspect everything in the
	    Explorer. (Edit-mode builds never yield.)

	  • Force a rebuild: Build(true) destroys Workspace.Map and the template
	    and regenerates them (Workspace.ActiveMatches is never touched).
	    After editing any MapGen module, bump MapBuilder.Version so stale
	    baked copies are replaced automatically on the next Play.
]]

local MapBuilder = require(script.Parent.MapGen.MapBuilder)

local ok, err = xpcall(function()
	MapBuilder.Build(false)
end, debug.traceback)

if not ok then
	warn(`[MapGenerator] map generation failed:\n{err}`)
end
