--!strict
--[[
	GameManager  (Script)  ·  ServerScriptService/GameManager

	Bootstrap only:
	  1. require Shared/Remotes (creates ReplicatedStorage.Remotes right away
	     so clients never wait) and answer GetState with an empty state
	     until the services exist;
	  2. wait for Workspace.Map to carry MapReady = true (poll forever,
	     warn every 10 s);
	  3. make sure Workspace.ActiveMatches exists;
	  4. create MatchService and QueueService and start the queue scan;
	  5. wire every client -> server remote (rate-limited, then handed to the
	     service that type-checks and validates it), Players events and the
	     GetState RemoteFunction.

	All game logic lives in ServerScriptService/Server.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local Config = require(Shared.Config)
local Names = require(Shared.Names)
local Remotes = require(Shared.Remotes)

local Server = script.Parent.Server
local MatchService = require(Server.MatchService)
local QueueService = require(Server.QueueService)
local RateLimiter = require(Server.RateLimiter)

local MAP_POLL_SECONDS = 0.25
local MAP_WARN_EVERY = 10

local function log(message: string)
	if Config.Debug.Verbose then
		print(`[GameManager] {message}`)
	end
end

-- Until the services exist, GetState answers "nothing yet" instead of hanging.
Remotes.GetState.OnServerInvoke = function(_player: Player): Remotes.ClientState
	return { queues = {}, queueIndex = nil, match = nil }
end

local function waitForMap(): Instance
	local started = os.clock()
	local lastWarning = started
	while true do
		local map = Workspace:FindFirstChild(Names.Map)
		if map and map:GetAttribute(Names.MapReadyAttribute) == true then
			return map
		end
		if os.clock() - lastWarning >= MAP_WARN_EVERY then
			lastWarning = os.clock()
			warn(
				`[GameManager] still waiting for Workspace.{Names.Map} with {Names.MapReadyAttribute} = true `
					.. `({math.floor(lastWarning - started)} s). Is the MapGenerator running?`
			)
		end
		task.wait(MAP_POLL_SECONDS)
	end
end

local function ensureActiveMatches(): Instance
	local existing = Workspace:FindFirstChild(Names.ActiveMatches)
	if existing then
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = Names.ActiveMatches
	folder.Parent = Workspace
	return folder
end

----------------------------------------------------------------------------
-- Boot
----------------------------------------------------------------------------

local map = waitForMap()
local activeMatches = ensureActiveMatches()
local matchService = MatchService.new(map, activeMatches)
local queueService = QueueService.new(map, matchService)
local limiter = RateLimiter.new(Config.RateLimit.PerSecond, Config.RateLimit.Burst)

-- Last GetState answer per player: what a rate-limited caller gets back.
local lastClientState: { [Player]: Remotes.ClientState } = setmetatable({}, { __mode = "k" }) :: any

----------------------------------------------------------------------------
-- Remotes
----------------------------------------------------------------------------

Remotes.SubmitCategory.OnServerEvent:Connect(function(player: Player, matchId: unknown, text: unknown)
	if limiter:allow(player, "SubmitCategory") then
		matchService:onSubmitCategory(player, matchId, text)
	end
end)

Remotes.SubmitAnswer.OnServerEvent:Connect(function(player: Player, matchId: unknown, turnId: unknown, text: unknown)
	if limiter:allow(player, "SubmitAnswer") then
		matchService:onSubmitAnswer(player, matchId, turnId, text)
	end
end)

Remotes.JudgeAnswer.OnServerEvent:Connect(function(player: Player, matchId: unknown, turnId: unknown, verdict: unknown)
	if limiter:allow(player, "JudgeAnswer") then
		matchService:onJudgeAnswer(player, matchId, turnId, verdict)
	end
end)

Remotes.LeaveQueue.OnServerEvent:Connect(function(player: Player)
	if limiter:allow(player, "LeaveQueue") then
		queueService:leaveQueue(player)
	end
end)

Remotes.QueueAction.OnServerEvent:Connect(function(player: Player, action: unknown, humans: unknown, bots: unknown)
	if limiter:allow(player, "QueueAction") then
		queueService:onQueueAction(player, action, humans, bots)
	end
end)

Remotes.GetState.OnServerInvoke = function(player: Player): Remotes.ClientState
	if not limiter:allow(player, "GetState") then
		local cached = lastClientState[player]
		if cached then
			return cached
		end
	end
	local state: Remotes.ClientState = {
		queues = queueService:getStatuses(),
		queueIndex = queueService:queueIndexOf(player),
		match = matchService:snapshotFor(player),
	}
	lastClientState[player] = state
	return state
end

----------------------------------------------------------------------------
-- Players
----------------------------------------------------------------------------

local function onPlayerAdded(player: Player)
	-- Late joiners get the current queue board immediately.
	Remotes.QueueStatus:FireClient(player, queueService:getStatuses())
end

Players.PlayerAdded:Connect(onPlayerAdded)
for _, player in Players:GetPlayers() do
	onPlayerAdded(player)
end

Players.PlayerRemoving:Connect(function(player: Player)
	queueService:onPlayerRemoving(player)
	matchService:onPlayerRemoving(player)
	limiter:forget(player)
	lastClientState[player] = nil
end)

queueService:start()
log(`ready: map {tostring(map:GetAttribute(Names.MapVersionAttribute))}, {Config.Match.MaxConcurrentMatches} room slots`)
