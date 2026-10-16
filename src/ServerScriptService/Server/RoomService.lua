--!strict
--[[
	RoomService  (ModuleScript)  ·  ServerScriptService/Server/RoomService

	Owns the physical world:
	  • finds the map (or asks MapBuilder to build a graybox)
	  • seats players in the Interrogation Room and keeps them seated
	  • teleports eliminated players and the bench into the Spectator Lounge
	  • drives the TV SurfaceGui and the lobby status board

	TV and lobby-board text is set HERE on the server, so it replicates to
	everyone automatically, late joiners included.

	Required Workspace names (see docs/STUDIO_SETUP.md):
	    Workspace.Lobby.LobbySpawn                       SpawnLocation
	    Workspace.Lobby.StatusBoard                      Part     (optional)
	    Workspace.InterrogationRoom.Seats.Seat1..Seat4   Seat
	    Workspace.InterrogationRoom.TVScreen             Part
	    Workspace.InterrogationRoom.TwoWayMirror         Part     (client-styled)
	    Workspace.SpectatorLounge.SpectatorSpawns.*      Parts
	    Workspace.CameraPoints.RoomCam / SpectatorCam    Parts    (client camera)
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterPlayer = game:GetService("StarterPlayer")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage.Shared.Config)
local MapBuilder = require(script.Parent.MapBuilder)

local RoomService = {}

RoomService.Colors = table.freeze({
	Paper = Color3.fromRGB(244, 237, 222),
	Amber = Color3.fromRGB(255, 196, 61),
	Red = Color3.fromRGB(235, 72, 72),
	Green = Color3.fromRGB(88, 214, 141),
	Blue = Color3.fromRGB(96, 165, 250),
	Muted = Color3.fromRGB(150, 156, 170),
})

type TV = {
	Header: TextLabel,
	Speaker: TextLabel,
	Body: TextLabel,
	Footer: TextLabel,
}

export type TVFields = {
	header: string?,
	speaker: string?,
	body: string?,
	footer: string?,
	bodyColor: Color3?,
	cursor: boolean?, -- append a blinking-style "_" (live typing)
}

local seats: { Seat } = {}
local seatAssignment: { [Seat]: Player } = {}
local lobbySpawn: BasePart? = nil
local spectatorSpawns: { BasePart } = {}
local tv: TV? = nil
local boardStatus: TextLabel? = nil

----------------------------------------------------------------------------
-- Map lookup
----------------------------------------------------------------------------
local function find(parent: Instance, path: string): Instance
	local current = parent
	for _, name in string.split(path, ".") do
		local child = current:WaitForChild(name, 10)
		if not child then
			error(`[RoomService] Missing {current:GetFullName()}.{name}. See docs/STUDIO_SETUP.md`)
		end
		current = child
	end
	return current
end

local function label(parent: Instance, name: string, props: { [string]: any }): TextLabel
	local textLabel = Instance.new("TextLabel")
	textLabel.Name = name
	textLabel.BackgroundTransparency = 1
	textLabel.TextScaled = true
	textLabel.TextColor3 = RoomService.Colors.Paper
	textLabel.Font = Enum.Font.BuilderSansBold
	textLabel.Text = ""
	for key, value in props do
		(textLabel :: any)[key] = value
	end
	textLabel.Parent = parent
	return textLabel
end

-- Use a designer-made TVGui if it has the four labels; otherwise build one.
local function setupTV(screen: BasePart)
	local existing = screen:FindFirstChild("TVGui")
	if existing then
		local header = existing:FindFirstChild("Header", true)
		local speaker = existing:FindFirstChild("Speaker", true)
		local body = existing:FindFirstChild("Body", true)
		local footer = existing:FindFirstChild("Footer", true)
		if header and speaker and body and footer then
			tv = {
				Header = header :: TextLabel,
				Speaker = speaker :: TextLabel,
				Body = body :: TextLabel,
				Footer = footer :: TextLabel,
			}
			return
		end
		existing:Destroy()
	end

	local gui = Instance.new("SurfaceGui")
	gui.Name = "TVGui"
	gui.Face = Enum.NormalId.Front
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 50
	gui.LightInfluence = 0
	gui.Brightness = 1.3
	gui.ClipsDescendants = true

	local background = Instance.new("Frame")
	background.Name = "Screen"
	background.Size = UDim2.fromScale(1, 1)
	background.BackgroundColor3 = Color3.fromRGB(10, 13, 20)
	background.BorderSizePixel = 0
	background.Parent = gui

	local gradient = Instance.new("UIGradient")
	gradient.Rotation = 90
	gradient.Color = ColorSequence.new(Color3.fromRGB(34, 40, 56), Color3.fromRGB(8, 10, 16))
	gradient.Parent = background

	local padding = Instance.new("UIPadding")
	padding.PaddingLeft = UDim.new(0.04, 0)
	padding.PaddingRight = UDim.new(0.04, 0)
	padding.PaddingTop = UDim.new(0.05, 0)
	padding.PaddingBottom = UDim.new(0.04, 0)
	padding.Parent = background

	local header = label(background, "Header", {
		Size = UDim2.fromScale(1, 0.16),
		Font = Enum.Font.SpecialElite,
		TextColor3 = RoomService.Colors.Amber,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = "CONCENTRATION 64",
	})
	header.ZIndex = 2

	local rule = Instance.new("Frame")
	rule.Name = "Rule"
	rule.Position = UDim2.fromScale(0, 0.185)
	rule.Size = UDim2.new(1, 0, 0, 3)
	rule.BackgroundColor3 = RoomService.Colors.Amber
	rule.BackgroundTransparency = 0.5
	rule.BorderSizePixel = 0
	rule.Parent = background

	label(background, "Speaker", {
		Position = UDim2.fromScale(0, 0.22),
		Size = UDim2.fromScale(1, 0.12),
		TextColor3 = RoomService.Colors.Muted,
		TextXAlignment = Enum.TextXAlignment.Left,
	})
	label(background, "Body", {
		Position = UDim2.fromScale(0, 0.37),
		Size = UDim2.fromScale(1, 0.44),
		Font = Enum.Font.FredokaOne,
		Text = "AWAITING SUSPECTS",
	})
	label(background, "Footer", {
		Position = UDim2.fromScale(0, 0.86),
		Size = UDim2.fromScale(0.7, 0.14),
		TextColor3 = RoomService.Colors.Muted,
		TextXAlignment = Enum.TextXAlignment.Left,
	})
	label(background, "Rec", {
		Position = UDim2.fromScale(0.7, 0.86),
		Size = UDim2.fromScale(0.3, 0.14),
		TextColor3 = RoomService.Colors.Red,
		TextXAlignment = Enum.TextXAlignment.Right,
		Text = "● REC",
	})

	gui.Parent = screen
	tv = {
		Header = background:FindFirstChild("Header") :: TextLabel,
		Speaker = background:FindFirstChild("Speaker") :: TextLabel,
		Body = background:FindFirstChild("Body") :: TextLabel,
		Footer = background:FindFirstChild("Footer") :: TextLabel,
	}
end

local function setupBoard(board: BasePart)
	local existing = board:FindFirstChild("BoardGui")
	local status = existing and existing:FindFirstChild("Status", true)
	if status and status:IsA("TextLabel") then
		boardStatus = status
		return
	end

	local gui = Instance.new("SurfaceGui")
	gui.Name = "BoardGui"
	gui.Face = Enum.NormalId.Front
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 40
	gui.LightInfluence = 0

	label(gui, "Title", {
		Position = UDim2.fromScale(0.05, 0.08),
		Size = UDim2.fromScale(0.9, 0.42),
		Font = Enum.Font.SpecialElite,
		TextColor3 = RoomService.Colors.Amber,
		Text = "CONCENTRATION 64",
	})
	boardStatus = label(gui, "Status", {
		Position = UDim2.fromScale(0.05, 0.58),
		Size = UDim2.fromScale(0.9, 0.3),
		Font = Enum.Font.FredokaOne,
		Text = "WAITING FOR SUSPECTS",
	})
	gui.Parent = board
end

----------------------------------------------------------------------------
-- Characters
----------------------------------------------------------------------------
local function getHumanoid(player: Player): Humanoid?
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid and humanoid.Health > 0 then
		return humanoid
	end
	return nil
end

local function setMovementLocked(humanoid: Humanoid, locked: boolean)
	if locked then
		humanoid.WalkSpeed = 0
		humanoid.JumpPower = 0
		humanoid.JumpHeight = 0 -- also hides the mobile jump button
	else
		humanoid.WalkSpeed = StarterPlayer.CharacterWalkSpeed
		humanoid.JumpPower = StarterPlayer.CharacterJumpPower
		humanoid.JumpHeight = StarterPlayer.CharacterJumpHeight
	end
end

local function unseat(humanoid: Humanoid)
	local seatPart = humanoid.SeatPart
	if seatPart then
		local weld = seatPart:FindFirstChild("SeatWeld")
		if weld then
			weld:Destroy()
		end
	end
	humanoid.Sit = false
end

local function teleport(player: Player, target: CFrame)
	local character = player.Character
	if not character then
		return
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		unseat(humanoid)
	end
	character:PivotTo(target + Vector3.new(0, 3, 0))
end

----------------------------------------------------------------------------
-- Public API
----------------------------------------------------------------------------
function RoomService.init()
	if Config.Map.AutoBuildGraybox and not Workspace:FindFirstChild("InterrogationRoom") then
		MapBuilder.build()
	end

	local room = find(Workspace, "InterrogationRoom")

	-- Seats: Seat1, Seat2, ... in turn order.
	local numbered: { { index: number, seat: Seat } } = {}
	for _, child in find(room, "Seats"):GetChildren() do
		local index = tonumber(string.match(child.Name, "^Seat(%d+)$"))
		if index and child:IsA("Seat") then
			table.insert(numbered, { index = index, seat = child })
		end
	end
	table.sort(numbered, function(a, b)
		return a.index < b.index
	end)
	for _, entry in numbered do
		table.insert(seats, entry.seat)
	end
	assert(#seats > 0, "[RoomService] InterrogationRoom.Seats needs Seat1..Seat4 (Seat objects)")
	if #seats < Config.Players.MaxActive then
		warn(`[RoomService] Only {#seats} seats found; rounds will use at most {#seats} players.`)
	end

	-- Keep assigned players seated; kick out anyone else.
	for seatIndex, seat in seats do
		seat.Disabled = false
		seat:GetPropertyChangedSignal("Occupant"):Connect(function()
			local occupant = seat.Occupant
			local assigned = seatAssignment[seat]
			if occupant then
				if Players:GetPlayerFromCharacter(occupant.Parent) ~= assigned then
					task.defer(function()
						if seat.Occupant == occupant then
							unseat(occupant)
						end
					end)
				end
			elseif assigned then
				task.delay(0.3, function()
					if seatAssignment[seat] == assigned and seat.Occupant == nil then
						RoomService.seat(assigned, seatIndex)
					end
				end)
			end
		end)
	end

	setupTV(find(room, "TVScreen") :: BasePart)

	local lounge = find(Workspace, "SpectatorLounge")
	for _, child in find(lounge, "SpectatorSpawns"):GetChildren() do
		if child:IsA("BasePart") then
			table.insert(spectatorSpawns, child)
		end
	end
	assert(#spectatorSpawns > 0, "[RoomService] SpectatorLounge.SpectatorSpawns needs at least one Part")

	local lobby = find(Workspace, "Lobby")
	lobbySpawn = find(lobby, "LobbySpawn") :: BasePart
	local board = lobby:FindFirstChild("StatusBoard")
	if board and board:IsA("BasePart") then
		setupBoard(board)
	end
end

function RoomService.seatCount(): number
	return #seats
end

-- Sit `player` in seat `index` and lock their movement.
function RoomService.seat(player: Player, index: number)
	local seat = seats[index]
	if not seat then
		return
	end
	seatAssignment[seat] = player

	local humanoid = getHumanoid(player)
	if not humanoid then
		return -- CharacterAdded will call us again
	end
	setMovementLocked(humanoid, true)
	if seat.Occupant == humanoid then
		return
	end
	if seat.Occupant then
		unseat(seat.Occupant)
	end
	unseat(humanoid)
	local character = humanoid.Parent :: Model
	character:PivotTo(seat.CFrame + Vector3.new(0, 2.5, 0))
	seat:Sit(humanoid)
end

-- Forget `player`'s seat (does not move them).
function RoomService.release(player: Player)
	for seat, assigned in seatAssignment do
		if assigned == player then
			seatAssignment[seat] = nil
		end
	end
end

function RoomService.clearSeats()
	table.clear(seatAssignment)
	for _, seat in seats do
		local occupant = seat.Occupant
		if occupant then
			unseat(occupant)
		end
	end
end

-- Eliminated / benched → behind the two-way mirror.
function RoomService.sendToLounge(player: Player)
	RoomService.release(player)
	local humanoid = getHumanoid(player)
	if humanoid then
		setMovementLocked(humanoid, false)
	end
	local spawn = spectatorSpawns[math.random(#spectatorSpawns)]
	teleport(player, spawn.CFrame)
end

function RoomService.sendToLobby(player: Player)
	RoomService.release(player)
	local humanoid = getHumanoid(player)
	if humanoid then
		setMovementLocked(humanoid, false)
	end
	local spawn = lobbySpawn
	if spawn then
		local jitter = CFrame.new(math.random(-20, 20) / 10, 0, math.random(-20, 20) / 10)
		teleport(player, spawn.CFrame * jitter)
	end
end

function RoomService.isNearLobby(player: Player): boolean
	local character = player.Character
	local spawn = lobbySpawn
	if not character or not spawn then
		return true
	end
	return (character:GetPivot().Position - spawn.Position).Magnitude < 120
end

-- Update any subset of the TV's text.
function RoomService.setTV(fields: TVFields)
	local screen = tv
	if not screen then
		return
	end
	if fields.header then
		screen.Header.Text = fields.header
	end
	if fields.speaker then
		screen.Speaker.Text = fields.speaker
	end
	if fields.body then
		screen.Body.Text = if fields.cursor then fields.body .. "_" else fields.body
	end
	if fields.footer then
		screen.Footer.Text = fields.footer
	end
	if fields.bodyColor then
		screen.Body.TextColor3 = fields.bodyColor
	end
end

function RoomService.setBoard(text: string)
	local status = boardStatus
	if status and status.Text ~= text then
		status.Text = text
	end
end

return RoomService
