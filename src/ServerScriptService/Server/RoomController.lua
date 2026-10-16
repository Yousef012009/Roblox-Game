--!strict
--[[
	RoomController  (ModuleScript)  ·  ServerScriptService/Server/RoomController

	Wraps ONE cloned interrogation module (Workspace.ActiveMatches.Match_<slot>)
	and hides its instance layout from Match:

	  • seats             Seats/SeatAnchor01..NN (Seat), looked up once
	  • spectator spawns  SpectatorSpawns/SpectatorSpawn01..NN, handed out
	                      "next free first" to eliminated players
	  • anchors           ModuleRoot and camera anchors (CameraAnchors/*);
	                      seats and spawns are force-anchored (static geometry)
	  • TV text           TVGui > Screen > Header/Category/Speaker/Answer/Footer;
	                      writes only when the text actually changes; a missing
	                      label is reported once and otherwise ignored

	Everything is looked up through Names (the naming contract).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Names = require(ReplicatedStorage.Shared.Names)

export type TVFields = {
	header: string?,
	category: string?,
	speaker: string?,
	answer: string?,
	footer: string?,
}

type RoomData = {
	model: Model,
	slot: number,
	seats: { [number]: Seat },
	seatCount: number,
	spectatorSpawns: { BasePart },
	spawnOwner: { [number]: number }, -- spectator spawn index -> userId
	tvFrame: Instance?,
	tvLabels: { [string]: TextLabel },
	tvWarned: { [string]: boolean },
	destroyed: boolean,
}

local RoomController = {}
RoomController.__index = RoomController

export type RoomController = typeof(setmetatable({} :: RoomData, RoomController))

local MAX_LOOKUP = 32 -- upper bound when probing numbered children (SeatAnchor01.., SpectatorSpawn01..)

-- Finds `name` directly under `parent`, or anywhere below it as a fallback.
local function findChild(parent: Instance?, name: string): Instance?
	if not parent then
		return nil
	end
	return parent:FindFirstChild(name) or parent:FindFirstChild(name, true)
end

local function collectSeats(model: Model): ({ [number]: Seat }, number)
	local seats: { [number]: Seat } = {}
	local count = 0
	local folder = findChild(model, Names.Seats)
	for index = 1, MAX_LOOKUP do
		local seat = findChild(folder or model, Names.SeatAnchor(index))
		if not seat then
			break
		end
		if seat:IsA("Seat") then
			-- Static geometry, and Seat:Sit does nothing on a Disabled seat.
			-- Strangers are kept out by Match's seat watchdog instead.
			seat.Anchored = true
			seat.Disabled = false
			seats[index] = seat
			count = index
		else
			warn(`[RoomController] {model.Name}: {seat.Name} is a {seat.ClassName}, expected a Seat`)
		end
	end
	return seats, count
end

local function collectSpectatorSpawns(model: Model): { BasePart }
	local spawns: { BasePart } = {}
	local folder = findChild(model, Names.SpectatorSpawns)
	for index = 1, MAX_LOOKUP do
		local spawnPart = findChild(folder or model, Names.SpectatorSpawn(index))
		if not spawnPart or not spawnPart:IsA("BasePart") then
			break
		end
		spawnPart.Anchored = true
		table.insert(spawns, spawnPart)
	end
	return spawns
end

function RoomController.new(model: Model, slot: number): RoomController
	local seats, seatCount = collectSeats(model)
	local self: RoomData = {
		model = model,
		slot = slot,
		seats = seats,
		seatCount = seatCount,
		spectatorSpawns = collectSpectatorSpawns(model),
		spawnOwner = {},
		tvFrame = nil,
		tvLabels = {},
		tvWarned = {},
		destroyed = false,
	}

	local moduleRoot = model:FindFirstChild(Names.ModuleRoot)
	if moduleRoot and moduleRoot:IsA("BasePart") then
		moduleRoot.Anchored = true
	end

	local tvGui = findChild(model, Names.TVGui)
	self.tvFrame = if tvGui then tvGui:FindFirstChild(Names.TVFrame) else nil
	if not self.tvFrame then
		warn(`[RoomController] {model.Name}: TV {Names.TVGui} > {Names.TVFrame} not found; TV text disabled`)
	end
	if seatCount == 0 then
		warn(`[RoomController] {model.Name}: no seats found under {Names.Seats}`)
	end
	if #self.spectatorSpawns == 0 then
		warn(`[RoomController] {model.Name}: no spectator spawns under {Names.SpectatorSpawns}`)
	end

	return setmetatable(self, RoomController)
end

----------------------------------------------------------------------------
-- Geometry
----------------------------------------------------------------------------

function RoomController.getModel(self: RoomController): Model
	return self.model
end

-- World position of the module origin (room centre on the floor).
function RoomController.getOrigin(self: RoomController): Vector3
	return self.model:GetPivot().Position
end

function RoomController.getSeat(self: RoomController, seatNumber: number): Seat?
	return self.seats[seatNumber]
end

function RoomController.getSeatCount(self: RoomController): number
	return self.seatCount
end

-- Seat number of a Seat instance belonging to this room, or nil.
function RoomController.seatNumberOf(self: RoomController, seat: Seat): number?
	for number, candidate in self.seats do
		if candidate == seat then
			return number
		end
	end
	return nil
end

-- Where a player of seat `seatNumber` should be streamed / placed.
function RoomController.seatPosition(self: RoomController, seatNumber: number): Vector3
	local seat = self.seats[seatNumber]
	return if seat then seat.Position else self:getOrigin()
end

function RoomController.getCameraAnchor(self: RoomController, name: string): BasePart?
	local anchors = findChild(self.model, Names.CameraAnchors)
	local anchor = findChild(anchors, name)
	if anchor and anchor:IsA("BasePart") then
		return anchor
	end
	return nil
end

----------------------------------------------------------------------------
-- Spectator lounge
----------------------------------------------------------------------------

-- The spawn this user should stand on: the one already assigned, else the
-- lowest-numbered free one, else (more spectators than spawns) one shared
-- round-robin. Returns nil when the room has no spawns at all.
function RoomController.spectatorSpawnFor(self: RoomController, userId: number): BasePart?
	local spawns = self.spectatorSpawns
	if #spawns == 0 then
		return nil
	end
	local taken = 0
	for index, owner in self.spawnOwner do
		if owner == userId then
			return spawns[index]
		end
		taken += 1
	end
	for index = 1, #spawns do
		if self.spawnOwner[index] == nil then
			self.spawnOwner[index] = userId
			return spawns[index]
		end
	end
	return spawns[taken % #spawns + 1]
end

-- Everyone goes back to their seat at the start of a round.
function RoomController.clearSpectatorSpawns(self: RoomController)
	table.clear(self.spawnOwner)
end

----------------------------------------------------------------------------
-- TV
----------------------------------------------------------------------------

function RoomController.getLabel(self: RoomController, name: string): TextLabel?
	local cached = self.tvLabels[name]
	if cached then
		return cached
	end
	local frame = self.tvFrame
	if not frame then
		return nil
	end
	local label = frame:FindFirstChild(name)
	if label and label:IsA("TextLabel") then
		self.tvLabels[name] = label
		return label
	end
	if not self.tvWarned[name] then
		self.tvWarned[name] = true
		warn(`[RoomController] {self.model.Name}: TV label {name} missing`)
	end
	return nil
end

function RoomController.setLabel(self: RoomController, name: string, text: string?)
	if text == nil or self.destroyed then
		return
	end
	local label = self:getLabel(name)
	if label and label.Text ~= text then
		label.Text = text
	end
end

-- Sets the given TV fields; omitted (nil) fields keep their current text.
function RoomController.setTV(self: RoomController, fields: TVFields)
	self:setLabel(Names.TVHeader, fields.header)
	self:setLabel(Names.TVCategory, fields.category)
	self:setLabel(Names.TVSpeaker, fields.speaker)
	self:setLabel(Names.TVAnswer, fields.answer)
	self:setLabel(Names.TVFooter, fields.footer)
end

----------------------------------------------------------------------------
-- Lifetime
----------------------------------------------------------------------------

function RoomController.destroy(self: RoomController)
	if self.destroyed then
		return
	end
	self.destroyed = true
	table.clear(self.tvLabels)
	table.clear(self.spawnOwner)
	self.model:Destroy()
end

return RoomController
