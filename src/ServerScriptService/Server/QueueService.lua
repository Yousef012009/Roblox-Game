--!strict
--[[
	QueueService  (ModuleScript)  ·  ServerScriptService/Server/QueueService

	The four elevator queues in the lobby (Workspace.Map.Queues.QueueNN).

	DETECTION
	  Every Config.Queue.ScanInterval the server tests each player's
	  HumanoidRootPart against each QueueNN_Trigger box in the trigger's own
	  space (PointToObjectSpace vs Size/2). Entering needs the plain box;
	  staying only needs the box grown by ExitMarginStuds (hysteresis), so
	  standing on the edge never flickers. Touched is not used.

	MEMBERSHIP
	  player -> queue map: a player is in at most one queue. Players in a
	  match, dead, or without a root part are never added. At most Capacity
	  members; players standing inside a full queue wait (FIFO by the time
	  they stepped in) until a slot frees. Disconnects remove instantly.

	STATES (Remotes.QueueState)
	  Open ──count ≥ required──► Starting (full: StartCountdownSeconds,
	        partial: PartialStartDelaySeconds, collapsing to the short
	        countdown as soon as the queue fills)
	  Starting ──count < required──► Open
	  Starting ──startsAt reached──► Departing (room slot reserved) | WaitingForRoom
	  WaitingForRoom ──slot frees──► Departing   (──count < required──► Open)
	  Departing: doors shut (DoorsOpen=false, DoorBlocker collides), wait
	        DepartSeconds, then COMMIT atomically: re-validate every member,
	        drop invalid ones, start the match if still ≥ required, else
	        back to Open; doors reopen.

	OUTPUT
	  QueueNN attributes (Count, State, DoorsOpen), the "n/4" display, the
	  status lights, Remotes.QueueStatus (to everyone, only when something
	  changed) and Remotes.QueueMembership (to a player whose membership
	  changed).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local Config = require(Shared.Config)
local Names = require(Shared.Names)
local Remotes = require(Shared.Remotes)

local CharacterUtil = require(script.Parent.CharacterUtil)
local MatchService = require(script.Parent.MatchService)

type QueueState = Remotes.QueueState

local LEAVE_COOLDOWN = 1.0 -- after LeaveQueue, ignore the player for this long (teleport settles)
local LIGHT_DIM_TRANSPARENCY = 0.6
local MAX_SCAN_WARNINGS = 5

type Queue = {
	index: number,
	model: Instance,
	trigger: BasePart,
	exit: BasePart?,
	label: TextLabel?,
	lightRed: BasePart?,
	lightGreen: BasePart?,
	blocker: BasePart?,

	members: { Player }, -- FIFO (entry order) = seat order of the match
	state: QueueState,
	startsAt: number?,
	reservedSlot: number?,

	-- Last values written to the world / sent to clients (change detection
	-- without per-scan allocations).
	shownCount: number?,
	shownState: QueueState?,
	shownSeconds: number?,
	shownFull: boolean?,
	sentCount: number?,
	sentState: QueueState?,
	sentStartsAt: number?,
}

type QueueServiceData = {
	matchService: MatchService.MatchService,
	queues: { Queue }, -- ordered by index
	required: number,
	playerQueue: { [Player]: Queue },
	waitingQueue: { [Player]: Queue }, -- standing inside a queue they are not (yet) a member of
	waitingSince: { [Player]: number },
	cooldownUntil: { [Player]: number },
	candidates: { Player }, -- scratch list reused every scan
	compareWaiting: (Player, Player) -> boolean,
	statuses: { Remotes.QueueStatus },
	running: boolean,
	scanFailures: number,
}

local QueueService = {}
QueueService.__index = QueueService

export type QueueService = typeof(setmetatable({} :: QueueServiceData, QueueService))

local function log(message: string)
	if Config.Debug.Verbose then
		print(`[QueueService] {message}`)
	end
end

-- Players needed before a queue may start: the Studio minimum while testing,
-- clamped to [3, Capacity] (3 = 1 Caller + 2 answerers is the smallest game).
local function requiredPlayers(): number
	local capacity = Config.Queue.Capacity
	local wanted = if RunService:IsStudio()
		then Config.Queue.StudioMinPlayersToStart
		else Config.Queue.MinPlayersToStart
	return math.clamp(wanted, math.min(3, capacity), capacity)
end

local function findPart(container: Instance, name: string): BasePart?
	local found = container:FindFirstChild(name, true)
	if found and found:IsA("BasePart") then
		return found
	end
	return nil
end

local function findDisplayLabel(display: BasePart?): TextLabel?
	if not display then
		return nil
	end
	local gui = display:FindFirstChild(Names.QueueDisplayGui, true)
	local label = if gui then gui:FindFirstChild(Names.QueueDisplayLabel, true) else nil
	if label and label:IsA("TextLabel") then
		return label
	end
	return nil
end

local function setLight(part: BasePart?, bright: boolean)
	if not part then
		return
	end
	part.Material = if bright then Enum.Material.Neon else Enum.Material.SmoothPlastic
	part.Transparency = if bright then 0 else LIGHT_DIM_TRANSPARENCY
	for _, child in part:GetChildren() do
		if child:IsA("Light") then
			child.Enabled = bright
		end
	end
end

local function buildQueue(queuesFolder: Instance, index: number): Queue?
	local model = queuesFolder:FindFirstChild(Names.Queue(index))
	if not model then
		warn(`[QueueService] {Names.Queue(index)} not found; queue disabled`)
		return nil
	end
	local trigger = findPart(model, Names.QueueTrigger(index))
	if not trigger then
		warn(`[QueueService] {Names.QueueTrigger(index)} not found; queue disabled`)
		return nil
	end
	local exit = findPart(model, Names.QueueExit(index))
	if not exit then
		warn(`[QueueService] {Names.QueueExit(index)} not found; LeaveQueue cannot move players out`)
	end
	local label = findDisplayLabel(findPart(model, Names.QueueDisplay(index)))
	if not label then
		warn(`[QueueService] {Names.QueueDisplay(index)} label not found; count display disabled`)
	end
	if model:GetAttribute(Names.AttrQueueIndex) == nil then
		model:SetAttribute(Names.AttrQueueIndex, index)
	end
	return {
		index = index,
		model = model,
		trigger = trigger,
		exit = exit,
		label = label,
		lightRed = findPart(model, Names.QueueLightRed(index)),
		lightGreen = findPart(model, Names.QueueLightGreen(index)),
		blocker = findPart(model, Names.QueueDoorBlocker(index)),
		members = {},
		state = "Open",
		startsAt = nil,
		reservedSlot = nil,
		shownCount = nil,
		shownState = nil,
		shownSeconds = nil,
		shownFull = nil,
		sentCount = nil,
		sentState = nil,
		sentStartsAt = nil,
	}
end

----------------------------------------------------------------------------
-- Construction
----------------------------------------------------------------------------

function QueueService.new(map: Instance, matchService: MatchService.MatchService): QueueService
	local waitingSince: { [Player]: number } = {}
	local self: QueueServiceData = {
		matchService = matchService,
		queues = {},
		required = requiredPlayers(),
		playerQueue = {},
		waitingQueue = {},
		waitingSince = waitingSince,
		cooldownUntil = {},
		candidates = {},
		-- Built once: earliest entry first, UserId as a stable tie-breaker.
		compareWaiting = function(a: Player, b: Player): boolean
			local timeA, timeB = waitingSince[a] or 0, waitingSince[b] or 0
			if timeA ~= timeB then
				return timeA < timeB
			end
			return a.UserId < b.UserId
		end,
		statuses = {},
		running = false,
		scanFailures = 0,
	}
	local service = setmetatable(self, QueueService)

	local queuesFolder = map:FindFirstChild(Names.Queues)
	if not queuesFolder then
		warn(`[QueueService] {Names.Map}.{Names.Queues} not found; no queues`)
	else
		for index = 1, Config.Queue.Count do
			local queue = buildQueue(queuesFolder, index)
			if queue then
				table.insert(service.queues, queue)
				service:setDoors(queue, true)
				service:refreshVisuals(queue, Workspace:GetServerTimeNow())
			end
		end
	end
	service.statuses = service:buildStatuses()
	log(`{#service.queues} queues, {service.required} players required to start`)
	return service
end

-- Starts the scan loop (idempotent).
function QueueService.start(self: QueueService)
	if self.running then
		return
	end
	self.running = true
	task.spawn(function()
		while self.running do
			local ok, err = pcall(self.scan, self)
			if not ok then
				-- Keep scanning; report the first few failures and then every 100th.
				self.scanFailures += 1
				if self.scanFailures <= MAX_SCAN_WARNINGS or self.scanFailures % 100 == 0 then
					warn(`[QueueService] scan failed ({self.scanFailures}): {err}`)
				end
			end
			task.wait(Config.Queue.ScanInterval)
		end
	end)
end

function QueueService.stop(self: QueueService)
	self.running = false
end

----------------------------------------------------------------------------
-- Queries
----------------------------------------------------------------------------

function QueueService.getStatuses(self: QueueService): { Remotes.QueueStatus }
	return self.statuses
end

function QueueService.queueIndexOf(self: QueueService, player: Player): number?
	local queue = self.playerQueue[player]
	return if queue then queue.index else nil
end

-- Connected, alive, with a root part, and not already in a match.
function QueueService.isEligible(self: QueueService, player: Player): boolean
	return player.Parent == Players and CharacterUtil.isAlive(player) and not self.matchService:isInMatch(player)
end

-- Is the player's root inside the trigger box grown by `margin` studs?
function QueueService.isInside(_self: QueueService, player: Player, queue: Queue, margin: number): boolean
	local root = CharacterUtil.getRoot(player)
	if not root then
		return false
	end
	local trigger = queue.trigger
	local offset = trigger.CFrame:PointToObjectSpace(root.Position)
	local half = trigger.Size * 0.5
	return math.abs(offset.X) <= half.X + margin
		and math.abs(offset.Y) <= half.Y + margin
		and math.abs(offset.Z) <= half.Z + margin
end

-- The queue whose ENTRY box (no margin) contains the player, if any.
function QueueService.queueAt(self: QueueService, player: Player): Queue?
	for _, queue in self.queues do
		if self:isInside(player, queue, 0) then
			return queue
		end
	end
	return nil
end

----------------------------------------------------------------------------
-- Membership
----------------------------------------------------------------------------

function QueueService.addMember(self: QueueService, queue: Queue, player: Player)
	table.insert(queue.members, player)
	self.playerQueue[player] = queue
	self.waitingQueue[player] = nil
	self.waitingSince[player] = nil
	Remotes.QueueMembership:FireClient(player, queue.index)
	log(`{player.Name} joined {Names.Queue(queue.index)} ({#queue.members})`)
end

-- Removes `player` from `queue`. `notify` sends QueueMembership(nil) when the
-- player is still connected.
function QueueService.removeMember(self: QueueService, queue: Queue, player: Player, notify: boolean)
	local position = table.find(queue.members, player)
	if position then
		table.remove(queue.members, position)
	end
	if self.playerQueue[player] == queue then
		self.playerQueue[player] = nil
	end
	if notify and player.Parent == Players then
		Remotes.QueueMembership:FireClient(player, nil)
	end
	log(`{player.Name} left {Names.Queue(queue.index)} ({#queue.members})`)
end

-- Drops members who walked out (beyond the hysteresis margin), died,
-- disconnected or ended up in a match.
function QueueService.pruneMembers(self: QueueService, queue: Queue)
	local members = queue.members
	for position = #members, 1, -1 do
		local player = members[position]
		if not self:isEligible(player) or not self:isInside(player, queue, Config.Queue.ExitMarginStuds) then
			self:removeMember(queue, player, true)
		end
	end
end

-- Adds players standing inside a queue's entry box, oldest arrival first,
-- while the queue has room and is not departing.
function QueueService.admitPlayers(self: QueueService, now: number)
	local candidates = self.candidates
	table.clear(candidates)
	for _, player in Players:GetPlayers() do
		local cooldown: number? = self.cooldownUntil[player]
		if cooldown and cooldown <= now then
			self.cooldownUntil[player] = nil
			cooldown = nil
		end

		local inside: Queue? = nil
		if self.playerQueue[player] == nil and cooldown == nil and self:isEligible(player) then
			inside = self:queueAt(player)
		end
		if inside then
			if self.waitingQueue[player] ~= inside then
				self.waitingQueue[player] = inside
				self.waitingSince[player] = now
			end
			table.insert(candidates, player)
		else
			self.waitingQueue[player] = nil
			self.waitingSince[player] = nil
		end
	end

	if #candidates > 1 then
		table.sort(candidates, self.compareWaiting)
	end
	for _, player in candidates do
		local queue = self.waitingQueue[player]
		if queue and queue.state ~= "Departing" and #queue.members < Config.Queue.Capacity then
			self:addMember(queue, player)
		end
	end
end

----------------------------------------------------------------------------
-- State machine
----------------------------------------------------------------------------

function QueueService.scan(self: QueueService)
	local now = Workspace:GetServerTimeNow()
	for _, queue in self.queues do
		-- A departing queue's riders are frozen; the commit re-validates them.
		if queue.state ~= "Departing" then
			self:pruneMembers(queue)
		end
	end
	self:admitPlayers(now)
	for _, queue in self.queues do
		self:updateQueue(queue, now)
	end
	self:broadcastIfChanged()
end

function QueueService.updateQueue(self: QueueService, queue: Queue, now: number)
	if queue.state ~= "Departing" then
		local count = #queue.members
		local capacity = Config.Queue.Capacity
		if count < self.required then
			queue.state = "Open"
			queue.startsAt = nil
		elseif queue.state == "Open" then
			queue.state = "Starting"
			queue.startsAt = now
				+ (if count >= capacity then Config.Queue.StartCountdownSeconds else Config.Queue.PartialStartDelaySeconds)
		elseif queue.state == "Starting" then
			local startsAt = queue.startsAt or now
			if count >= capacity then
				-- A full queue never waits longer than the short countdown.
				startsAt = math.min(startsAt, now + Config.Queue.StartCountdownSeconds)
			end
			queue.startsAt = startsAt
			if now >= startsAt then
				self:beginDeparture(queue)
			end
		elseif queue.state == "WaitingForRoom" then
			self:beginDeparture(queue)
		end
	end
	self:refreshVisuals(queue, now)
end

function QueueService.beginDeparture(self: QueueService, queue: Queue)
	local slot = self.matchService:reserveSlot()
	if slot == nil then
		if queue.state ~= "WaitingForRoom" then
			log(`{Names.Queue(queue.index)} waiting for a free room`)
		end
		queue.state = "WaitingForRoom"
		queue.startsAt = nil
		return
	end
	queue.state = "Departing"
	queue.startsAt = nil
	queue.reservedSlot = slot
	self:setDoors(queue, false)
	log(`{Names.Queue(queue.index)} departing to slot {slot}`)
	task.delay(Config.Queue.DepartSeconds, function()
		self:commitDeparture(queue)
	end)
end

-- Runs after DepartSeconds. Whatever happens, the queue ends up Open with its
-- doors open and the slot reservation consumed or released.
function QueueService.commitDeparture(self: QueueService, queue: Queue)
	local slot = queue.reservedSlot
	queue.reservedSlot = nil
	local ok, err = pcall(self.launch, self, queue, slot)
	if not ok then
		warn(`[QueueService] {Names.Queue(queue.index)} departure failed: {err}`)
		if slot ~= nil then
			self.matchService:releaseReservation(slot)
		end
	end
	queue.state = "Open"
	queue.startsAt = nil
	self:setDoors(queue, true)
	self:updateQueue(queue, Workspace:GetServerTimeNow())
	self:broadcastIfChanged()
end

-- The atomic commit (no yields): re-validate, then hand the riders to
-- MatchService and remove them from the queue in the same step.
function QueueService.launch(self: QueueService, queue: Queue, slot: number?)
	local members = queue.members
	for position = #members, 1, -1 do
		local player = members[position]
		if not self:isEligible(player) or not self:isInside(player, queue, Config.Queue.ExitMarginStuds) then
			self:removeMember(queue, player, true)
		end
	end

	if #members < self.required then
		log(`{Names.Queue(queue.index)} departure cancelled ({#members} valid riders)`)
		if slot ~= nil then
			self.matchService:releaseReservation(slot)
		end
		return
	end

	local riders = table.clone(members)
	local match = self.matchService:startMatch(riders, queue.index, slot)
	if not match then
		warn(`[QueueService] {Names.Queue(queue.index)}: the match could not start; riders stay queued`)
		return
	end
	for _, player in riders do
		if self.playerQueue[player] == queue then
			self.playerQueue[player] = nil
		end
		if player.Parent == Players then
			Remotes.QueueMembership:FireClient(player, nil)
		end
	end
	table.clear(members)
end

----------------------------------------------------------------------------
-- World + network output
----------------------------------------------------------------------------

function QueueService.setDoors(_self: QueueService, queue: Queue, open: boolean)
	queue.model:SetAttribute(Names.AttrDoorsOpen, open)
	if queue.blocker then
		queue.blocker.CanCollide = not open
	end
end

-- Attributes, "n/4" label and lights. Writes only what changed.
function QueueService.refreshVisuals(_self: QueueService, queue: Queue, now: number)
	local count = #queue.members
	local capacity = Config.Queue.Capacity
	local state: QueueState = queue.state
	local startsAt = queue.startsAt
	local seconds = if state == "Starting" and startsAt then math.max(0, math.ceil(startsAt - now)) else -1

	if queue.shownCount ~= count then
		queue.model:SetAttribute(Names.AttrQueueCount, count)
	end
	if queue.shownState ~= state then
		queue.model:SetAttribute(Names.AttrQueueState, state)
	end
	local label = queue.label
	if label and (queue.shownCount ~= count or queue.shownState ~= state or queue.shownSeconds ~= seconds) then
		local text = `{count}/{capacity}`
		if seconds >= 0 then
			text ..= string.format("  %d:%02d", seconds // 60, seconds % 60)
		elseif state == "WaitingForRoom" then
			text ..= "  WAIT"
		end
		label.Text = text
	end
	queue.shownCount = count
	queue.shownState = state
	queue.shownSeconds = seconds

	-- Green = come in; red = full or leaving.
	local full = state == "Departing" or state == "WaitingForRoom" or count >= capacity
	if queue.shownFull ~= full then
		queue.shownFull = full
		setLight(queue.lightGreen, not full)
		setLight(queue.lightRed, full)
	end
end

function QueueService.buildStatuses(self: QueueService): { Remotes.QueueStatus }
	local statuses: { Remotes.QueueStatus } = table.create(#self.queues)
	for _, queue in self.queues do
		table.insert(statuses, {
			index = queue.index,
			count = #queue.members,
			capacity = Config.Queue.Capacity,
			state = queue.state,
			startsAt = if queue.state == "Starting" then queue.startsAt else nil,
		})
	end
	return statuses
end

-- FireAllClients(QueueStatus) only when a count, state or start time changed.
function QueueService.broadcastIfChanged(self: QueueService)
	local changed = false
	for _, queue in self.queues do
		local count = #queue.members
		if queue.sentCount ~= count or queue.sentState ~= queue.state or queue.sentStartsAt ~= queue.startsAt then
			queue.sentCount = count
			queue.sentState = queue.state
			queue.sentStartsAt = queue.startsAt
			changed = true
		end
	end
	if changed then
		self.statuses = self:buildStatuses()
		Remotes.QueueStatus:FireAllClients(self.statuses)
	end
end

----------------------------------------------------------------------------
-- Player input / lifecycle
----------------------------------------------------------------------------

-- LeaveQueue remote: allowed unless the doors are already closing.
function QueueService.leaveQueue(self: QueueService, player: Player)
	local queue = self.playerQueue[player]
	if not queue or queue.state == "Departing" then
		return
	end
	local now = Workspace:GetServerTimeNow()
	self:removeMember(queue, player, true)
	self.waitingQueue[player] = nil
	self.waitingSince[player] = nil
	self.cooldownUntil[player] = now + LEAVE_COOLDOWN
	if queue.exit then
		CharacterUtil.teleport(player, queue.exit.CFrame)
	end
	self:updateQueue(queue, now)
	self:broadcastIfChanged()
end

function QueueService.onPlayerRemoving(self: QueueService, player: Player)
	local queue = self.playerQueue[player]
	if queue then
		self:removeMember(queue, player, false)
	end
	self.waitingQueue[player] = nil
	self.waitingSince[player] = nil
	self.cooldownUntil[player] = nil
	if queue then
		self:updateQueue(queue, Workspace:GetServerTimeNow())
		self:broadcastIfChanged()
	end
end

return QueueService
