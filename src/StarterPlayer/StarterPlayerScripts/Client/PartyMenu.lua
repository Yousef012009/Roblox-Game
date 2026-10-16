--!strict
--[[
	PartyMenu  (ModuleScript)  ·  StarterPlayerScripts/Client/PartyMenu

	The one queue UI (replaces the old QueueHUD). Lobby-only.

	Not queued: a slim hint, "WALK INTO AN ELEVATOR TO QUEUE".

	Queued (QueueMembership): the elevator's case-setup panel slides in:
	  ELEVATOR 02                                              [▾]
	  HUMANS INSIDE 2/3 · 3 AI DETECTIVES
	  DOORS CLOSE IN 0:04
	  INSIDE: AVA (HOST) · BO
	  PLAYERS   [-] 3 [+]          (humans to wait for, 1..Capacity)
	  BOTS      [-] 3 [+]          (0..Capacity - players)
	  TOTAL 6 / 8                  MIN 3: BOTS WILL BE ADDED
	  [ START NOW ]  [ LEAVE ]

	Only the HOST (QueueStatus.hostUserId) can change it: taps update the
	numbers at once and send Remotes.QueueAction("SetParty", humans, bots)
	after a short debounce; everyone else sees the live values read-only with
	"THE HOST SETS UP THE CASE". The panel collapses to a small pill so it
	never blocks walking, fits 390x844 portrait (top centre) and 844x390
	landscape (top right) through a viewport-fit UIScale, and every touch
	target is >= 44 px.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage.Shared.Config)
local Names = require(ReplicatedStorage.Shared.Names)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local State = require(script.Parent.State)
local UIKit = require(script.Parent.UIKit)

local PartyMenu = {}

local CAPACITY = Config.Queue.Capacity
local MIN_PARTICIPANTS = Config.Queue.MinParticipants
local DEBOUNCE = 0.35 -- seconds after the last tap before SetParty is sent
local ECHO_GRACE = 1.5 -- keep showing our own values this long while the server echoes
local SCAN_INTERVAL = 0.5 -- "who is inside" refresh
local PANEL_WIDTH = 340
local PANEL_HEIGHT = 322
local PILL_WIDTH = 300
local EDGE = 8
local ROW = UIKit.TouchMin

type Stepper = { minus: TextButton, plus: TextButton, value: TextLabel }
type Desired = { humans: number, bots: number, sentHumans: number, sentBots: number, sentAt: number }

local gui: ScreenGui
local hint: TextLabel
local panel: Frame
local pill: TextButton
local titleLabel: TextLabel
local collapseButton: TextButton
local statusLabel: TextLabel
local stateLabel: TextLabel
local whoLabel: TextLabel
local totalLabel: TextLabel
local noteLabel: TextLabel
local playersStepper: Stepper
local botsStepper: Stepper
local startButton: TextButton
local leaveButton: TextButton

local visible = false -- lobby (true) vs match (false)
local collapsed = false
local shownIndex: number? = nil -- queue the panel currently describes
local desired: Desired? = nil
local sendAt = 0 -- os.clock() when a debounced SetParty is due (0 = none)
local lastSeconds = -1
local scanAccumulator = SCAN_INTERVAL
local startLockedUntil = 0
local leaveLockedUntil = 0
local landscape = false

----------------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------------
local function plural(n: number, word: string): string
	return if n == 1 then `{n} {word}` else `{n} {word}S`
end

local function status(): State.QueueStatus?
	local index = State.queueIndex
	return if index then State.queues[index] else nil
end

local function isHost(): boolean
	local s = status()
	return s ~= nil and s.hostUserId == State.localUserId
end

local function locked(): boolean
	local s = status()
	return s ~= nil and s.state == "Departing"
end

-- Values to display: our own pending / just-sent choice wins until the
-- server echoes it (or ECHO_GRACE passes with something else).
local function shownValues(): (number, number)
	local s = status()
	local d = desired
	if d then
		if sendAt > 0 or os.clock() - d.sentAt < ECHO_GRACE then
			return d.humans, d.bots
		end
		if s and s.wantedHumans == d.sentHumans and s.bots == d.sentBots then
			return d.humans, d.bots
		end
		desired = nil
	end
	if s then
		local humans = math.clamp(math.floor(tonumber(s.wantedHumans) or Config.Queue.DefaultHumans), 1, CAPACITY)
		local bots = math.clamp(math.floor(tonumber(s.bots) or Config.Queue.DefaultBots), 0, CAPACITY - humans)
		return humans, bots
	end
	return Config.Queue.DefaultHumans, Config.Queue.DefaultBots
end

local function sendParty()
	local d = desired
	sendAt = 0
	if not d or not isHost() or locked() then
		return
	end
	-- The server requires humans + bots >= MinParticipants: top bots up (the
	-- hint tells the host they will be added) but keep showing their choice.
	local bots = math.clamp(math.max(d.bots, MIN_PARTICIPANTS - d.humans), 0, CAPACITY - d.humans)
	d.sentHumans = d.humans
	d.sentBots = bots
	d.sentAt = os.clock()
	Remotes.QueueAction:FireServer("SetParty", d.humans, bots)
end

local function change(dHumans: number, dBots: number)
	if not isHost() or locked() then
		return
	end
	local humans, bots = shownValues()
	humans = math.clamp(humans + dHumans, 1, CAPACITY)
	bots = math.clamp(bots + dBots, 0, CAPACITY - humans)
	local d = desired
	if d then
		d.humans, d.bots = humans, bots
	else
		desired = { humans = humans, bots = bots, sentHumans = -1, sentBots = -1, sentAt = -math.huge }
	end
	sendAt = os.clock() + DEBOUNCE
	PartyMenu.update()
end

----------------------------------------------------------------------------
-- Build
----------------------------------------------------------------------------
local function rowLabel(text: string, y: number): TextLabel
	return UIKit.label({
		Text = text,
		Font = UIKit.Fonts.Header,
		TextColor3 = UIKit.Colors.TextDim,
		TextXAlignment = Enum.TextXAlignment.Left,
		Position = UDim2.fromOffset(0, y),
		Size = UDim2.new(0.42, 0, 0, ROW),
		ZIndex = 13,
		Parent = panel,
	}, 20, 10)
end

local function stepper(name: string, y: number, onMinus: () -> (), onPlus: () -> ()): Stepper
	local holder = UIKit.new("Frame", {
		Name = name,
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, 0, 0, y),
		Size = UDim2.fromOffset(ROW * 3 + 12, ROW),
		ZIndex = 13,
		Parent = panel,
	})
	local minus = UIKit.button({
		Name = "Minus",
		Text = "-",
		Size = UDim2.fromOffset(ROW, ROW),
		ZIndex = 14,
		Parent = holder,
	}, UIKit.Colors.Phosphor, 26)
	local value = UIKit.label({
		Name = "Value",
		Font = UIKit.Fonts.Display,
		TextColor3 = UIKit.Colors.Text,
		BackgroundColor3 = UIKit.Colors.Black,
		BackgroundTransparency = 0.4,
		Position = UDim2.fromOffset(ROW + 6, 0),
		Size = UDim2.fromOffset(ROW, ROW),
		ZIndex = 14,
		Parent = holder,
	}, 26, 12)
	local plus = UIKit.button({
		Name = "Plus",
		Text = "+",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(1, 0),
		Size = UDim2.fromOffset(ROW, ROW),
		ZIndex = 14,
		Parent = holder,
	}, UIKit.Colors.Phosphor, 26)
	minus.Activated:Connect(function()
		if minus.Active then
			onMinus()
		end
	end)
	plus.Activated:Connect(function()
		if plus.Active then
			onPlus()
		end
	end)
	return { minus = minus, plus = plus, value = value }
end

local function setCollapsed(on: boolean)
	collapsed = on
	PartyMenu.update()
end

function PartyMenu.mount(parent: ScreenGui)
	gui = parent
	hint = UIKit.label({
		Name = "QueueHint",
		Text = "WALK INTO AN ELEVATOR TO QUEUE",
		TextColor3 = UIKit.Colors.TextDim,
		BackgroundColor3 = UIKit.Colors.Panel,
		BackgroundTransparency = 0.45,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 6),
		Size = UDim2.new(0.92, 0, 0, 24),
		Visible = false,
		ZIndex = 12,
		Parent = parent,
	}, 14)
	UIKit.sizeLimit(Vector2.new(0, 0), Vector2.new(400, 24)).Parent = hint

	panel = UIKit.panel({
		Name = "PartyMenu",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 6),
		Size = UDim2.fromOffset(PANEL_WIDTH, PANEL_HEIGHT),
		Visible = false,
		Active = true, -- taps on the panel never fall through to the world
		ZIndex = 12,
		Parent = parent,
	})
	UIKit.padding(10).Parent = panel
	UIKit.new("Frame", { -- phosphor accent along the top edge
		BorderSizePixel = 0,
		BackgroundColor3 = UIKit.Colors.Phosphor,
		Position = UDim2.new(0, -10, 0, -10),
		Size = UDim2.new(1, 20, 0, 2),
		ZIndex = 13,
		Parent = panel,
	})

	titleLabel = UIKit.label({
		Font = UIKit.Fonts.Header,
		TextColor3 = UIKit.Colors.Phosphor,
		TextXAlignment = Enum.TextXAlignment.Left,
		Size = UDim2.new(1, -ROW - 6, 0, ROW),
		ZIndex = 13,
		Parent = panel,
	}, 28, 12)
	collapseButton = UIKit.button({
		Name = "Collapse",
		Text = "▴",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(1, 0),
		Size = UDim2.fromOffset(ROW, ROW),
		ZIndex = 14,
		Parent = panel,
	}, UIKit.Colors.Text, 22)
	collapseButton.Activated:Connect(function()
		setCollapsed(true)
	end)

	statusLabel = UIKit.label({
		TextXAlignment = Enum.TextXAlignment.Left,
		Position = UDim2.fromOffset(0, 46),
		Size = UDim2.new(1, 0, 0, 20),
		ZIndex = 13,
		Parent = panel,
	}, 16, 9)
	stateLabel = UIKit.label({
		TextColor3 = UIKit.Colors.Amber,
		TextXAlignment = Enum.TextXAlignment.Left,
		Position = UDim2.fromOffset(0, 68),
		Size = UDim2.new(1, 0, 0, 20),
		ZIndex = 13,
		Parent = panel,
	}, 16, 9)
	whoLabel = UIKit.label({
		TextColor3 = UIKit.Colors.TextDim,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Position = UDim2.fromOffset(0, 90),
		Size = UDim2.new(1, 0, 0, 18),
		ZIndex = 13,
		Parent = panel,
	}, 14, 8)
	UIKit.new("Frame", {
		BorderSizePixel = 0,
		BackgroundColor3 = UIKit.Colors.Border,
		BackgroundTransparency = 0.3,
		Position = UDim2.fromOffset(0, 112),
		Size = UDim2.new(1, 0, 0, 1),
		ZIndex = 13,
		Parent = panel,
	})

	rowLabel("PLAYERS", 118)
	playersStepper = stepper("PlayersStepper", 118, function()
		change(-1, 0)
	end, function()
		change(1, 0)
	end)
	rowLabel("BOTS", 166)
	botsStepper = stepper("BotsStepper", 166, function()
		change(0, -1)
	end, function()
		change(0, 1)
	end)

	totalLabel = UIKit.label({
		Font = UIKit.Fonts.Display,
		TextColor3 = UIKit.Colors.Text,
		TextXAlignment = Enum.TextXAlignment.Left,
		Position = UDim2.fromOffset(0, 214),
		Size = UDim2.new(1, 0, 0, 20),
		ZIndex = 13,
		Parent = panel,
	}, 18, 9)
	noteLabel = UIKit.label({
		TextColor3 = UIKit.Colors.Amber,
		TextXAlignment = Enum.TextXAlignment.Left,
		Position = UDim2.fromOffset(0, 236),
		Size = UDim2.new(1, 0, 0, 18),
		ZIndex = 13,
		Parent = panel,
	}, 14, 8)

	startButton = UIKit.button({
		Name = "StartNow",
		Text = "START NOW",
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.fromScale(0, 1),
		Size = UDim2.new(0.5, -4, 0, ROW),
		ZIndex = 14,
		Parent = panel,
	}, UIKit.Colors.Phosphor, 18)
	startButton.Activated:Connect(function()
		if not startButton.Active or not isHost() or locked() then
			return
		end
		if sendAt > 0 then
			sendParty() -- flush the pending setup first so the start uses it
		end
		Remotes.QueueAction:FireServer("StartNow")
		startLockedUntil = os.clock() + 1.5
		UIKit.setEnabled(startButton, false)
	end)
	leaveButton = UIKit.button({
		Name = "Leave",
		Text = "LEAVE",
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.fromScale(1, 1),
		Size = UDim2.new(0.5, -4, 0, ROW),
		ZIndex = 14,
		Parent = panel,
	}, UIKit.Colors.Red, 18)
	leaveButton.Activated:Connect(function()
		if not leaveButton.Active or locked() then
			return
		end
		Remotes.LeaveQueue:FireServer()
		-- Re-armed by step() in case the server refused; a membership update hides the panel.
		leaveLockedUntil = os.clock() + 1.5
		UIKit.setEnabled(leaveButton, false)
	end)

	pill = UIKit.button({
		Name = "PartyPill",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 6),
		Size = UDim2.fromOffset(PILL_WIDTH, ROW),
		TextXAlignment = Enum.TextXAlignment.Left,
		Visible = false,
		ZIndex = 12,
		Parent = parent,
	}, UIKit.Colors.Phosphor, 16)
	pill.Activated:Connect(function()
		setCollapsed(false)
	end)

	parent:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		PartyMenu.layout()
	end)
	PartyMenu.layout()
end

----------------------------------------------------------------------------
-- Layout: portrait = top centre, landscape = top right; shrink to fit.
----------------------------------------------------------------------------
function PartyMenu.layout()
	local size = gui.AbsoluteSize
	if size.X <= 0 or size.Y <= 0 then
		return
	end
	landscape = size.X > size.Y * 1.15
	local fit = math.min(1, (size.Y - EDGE * 2) / PANEL_HEIGHT, (size.X - EDGE * 2) / PANEL_WIDTH)
	fit = math.max(fit, 0.55)
	panel:SetAttribute("BaseScale", fit)
	UIKit.scaleOf(panel).Scale = fit
	local anchor = if landscape then Vector2.new(1, 0) else Vector2.new(0.5, 0)
	local position = if landscape then UDim2.new(1, -EDGE, 0, 6) else UDim2.new(0.5, 0, 0, 6)
	panel.AnchorPoint = anchor
	UIKit.setRestPosition(panel, position)
	pill.AnchorPoint = anchor
	UIKit.setRestPosition(pill, position)
	pill.Size = UDim2.fromOffset(math.min(PILL_WIDTH, size.X - EDGE * 2), ROW)
end

----------------------------------------------------------------------------
-- Content
----------------------------------------------------------------------------
local function stateText(s: State.QueueStatus?, humans: number): string
	if not s then
		return "CONNECTING..."
	end
	if s.state == "Starting" then
		local startsAt = s.startsAt
		return if startsAt then `DOORS CLOSE IN {UIKit.clock(startsAt - State.now())}` else "DOORS CLOSING"
	elseif s.state == "Departing" then
		return "DOORS CLOSED · GOING DOWN ▼"
	elseif s.state == "WaitingForRoom" then
		return "ALL ROOMS BUSY · WAITING FOR A ROOM"
	end
	local missing = humans - (s.count or 0)
	if missing > 0 then
		return `WAITING FOR {plural(missing, "MORE DETECTIVE")}`
	end
	return "EVERYONE'S HERE · DOORS CLOSING SOON"
end

local function pillState(s: State.QueueStatus?): string
	if not s then
		return ""
	elseif s.state == "Starting" and s.startsAt then
		return `  ·  {UIKit.clock(s.startsAt - State.now())}`
	elseif s.state == "Departing" then
		return "  ·  ▼"
	elseif s.state == "WaitingForRoom" then
		return "  ·  WAIT"
	end
	return ""
end

local function pillText(index: number, s: State.QueueStatus?, humans: number): string
	local count = if s then s.count or 0 else 0
	local bots = if s then s.bots or 0 else 0
	local plusBots = if bots > 0 then ` +{bots} AI` else ""
	return string.format("▾ ELEVATOR %02d  ·  %d/%d%s%s", index, count, humans, plusBots, pillState(s))
end

local function setStepper(st: Stepper, value: number, minValue: number, maxValue: number, editable: boolean)
	UIKit.setText(st.value, tostring(value))
	UIKit.setVisible(st.minus, editable)
	UIKit.setVisible(st.plus, editable)
	UIKit.setEnabled(st.minus, editable and value > minValue)
	UIKit.setEnabled(st.plus, editable and value < maxValue)
end

-- Who is standing inside the chamber (cheap: one box test per player).
local function scanInside(index: number): string
	local map = Workspace:FindFirstChild(Names.Map)
	local trigger = map and map:FindFirstChild(Names.QueueTrigger(index), true)
	if not trigger or not trigger:IsA("BasePart") then
		return ""
	end
	local s = State.queues[index]
	local hostId = if s then s.hostUserId else nil
	local half = trigger.Size / 2 + Vector3.new(1, 1, 1)
	local names = {}
	for _, player in Players:GetPlayers() do
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if root and root:IsA("BasePart") then
			local offset = trigger.CFrame:PointToObjectSpace(root.Position)
			if math.abs(offset.X) <= half.X and math.abs(offset.Y) <= half.Y and math.abs(offset.Z) <= half.Z then
				local name = if player == Players.LocalPlayer then "YOU" else string.upper(player.DisplayName)
				if player.UserId == hostId then
					table.insert(names, 1, `{name} (HOST)`)
				else
					table.insert(names, name)
				end
			end
		end
	end
	return if #names > 0 then `INSIDE: {table.concat(names, " · ")}` else ""
end

-- Rebuilds every text / state (status or membership changed, or a tap).
function PartyMenu.update()
	local index = State.queueIndex
	if index ~= shownIndex then
		-- New queue (or none): start expanded with no stale local choice.
		shownIndex = index
		collapsed = false
		desired = nil
		sendAt = 0
		scanAccumulator = SCAN_INTERVAL
		UIKit.setText(whoLabel, "")
	end
	lastSeconds = -1
	local queued = visible and index ~= nil
	UIKit.setVisible(hint, visible and index == nil)
	if not queued then
		UIKit.setVisible(panel, false)
		UIKit.setVisible(pill, false)
		return
	end
	local queueIndex = index :: number
	local s = status()
	local host = isHost()
	local isLocked = locked()
	local humans, bots = shownValues()
	local count = if s then s.count or 0 else 0
	local liveBots = if s then s.bots or 0 else bots

	UIKit.setText(titleLabel, string.format("ELEVATOR %02d", queueIndex))
	UIKit.setText(
		statusLabel,
		`HUMANS INSIDE {count}/{humans}  ·  {if liveBots == 0 then "NO AI DETECTIVES" else plural(liveBots, "AI DETECTIVE")}`
	)
	UIKit.setText(stateLabel, stateText(s, humans))
	stateLabel.TextColor3 = if s and s.state == "Starting" then UIKit.Colors.Amber else UIKit.Colors.Phosphor

	setStepper(playersStepper, humans, 1, CAPACITY, host and not isLocked)
	setStepper(botsStepper, bots, 0, CAPACITY - humans, host and not isLocked)
	local total = humans + bots
	UIKit.setText(totalLabel, `TOTAL {total} / {CAPACITY}`)
	local note
	if not host then
		note = "THE HOST SETS UP THE CASE"
		noteLabel.TextColor3 = UIKit.Colors.TextDim
	elseif total < MIN_PARTICIPANTS then
		note = `MIN {MIN_PARTICIPANTS}: BOTS WILL BE ADDED`
		noteLabel.TextColor3 = UIKit.Colors.Amber
	elseif count + liveBots < MIN_PARTICIPANTS then
		note = `START NOW ADDS AI UP TO {MIN_PARTICIPANTS}`
		noteLabel.TextColor3 = UIKit.Colors.TextDim
	else
		note = "YOU ARE THE HOST"
		noteLabel.TextColor3 = UIKit.Colors.Phosphor
	end
	UIKit.setText(noteLabel, note)

	-- Host: START NOW + LEAVE side by side; guests: LEAVE across the row.
	UIKit.setVisible(startButton, host)
	leaveButton.Size = if host then UDim2.new(0.5, -4, 0, ROW) else UDim2.new(1, 0, 0, ROW)
	UIKit.setEnabled(startButton, host and not isLocked and os.clock() >= startLockedUntil)
	UIKit.setEnabled(leaveButton, not isLocked and os.clock() >= leaveLockedUntil)

	UIKit.setText(pill, pillText(queueIndex, s, humans))

	if collapsed then
		UIKit.setVisible(panel, false)
		UIKit.reveal(pill, -10)
	else
		UIKit.setVisible(pill, false)
		UIKit.reveal(panel, -18)
	end
end

-- Lobby (true) vs in a match (false).
function PartyMenu.setVisible(on: boolean)
	if on == visible then
		return
	end
	visible = on
	if not on then
		UIKit.setVisible(hint, false)
		UIKit.setVisible(panel, false)
		UIKit.setVisible(pill, false)
		return
	end
	PartyMenu.layout()
	PartyMenu.update()
end

function PartyMenu.isOpen(): boolean
	return visible and State.queueIndex ~= nil and not collapsed
end

-- Debounced send, countdown text (once a second), button re-arm, who-scan.
function PartyMenu.step(dt: number)
	local index = State.queueIndex
	if not visible or not index then
		return
	end
	local now = os.clock()
	if sendAt > 0 and now >= sendAt then
		sendParty()
	end
	if
		(startLockedUntil > 0 and now >= startLockedUntil)
		or (leaveLockedUntil > 0 and now >= leaveLockedUntil)
	then
		startLockedUntil = 0
		leaveLockedUntil = 0
		PartyMenu.update()
	end
	local s = State.queues[index]
	if s and s.state == "Starting" and s.startsAt then
		local seconds = math.max(0, math.ceil(s.startsAt - State.now()))
		if seconds ~= lastSeconds then
			lastSeconds = seconds
			local humans = shownValues()
			UIKit.setText(stateLabel, stateText(s, humans))
			UIKit.setText(pill, pillText(index, s, humans))
			if seconds <= 3 and not collapsed then
				UIKit.pulse(stateLabel, 1.12, 0.25)
			end
		end
	end
	if not collapsed then
		scanAccumulator += dt
		if scanAccumulator >= SCAN_INTERVAL then
			scanAccumulator = 0
			UIKit.setText(whoLabel, scanInside(index))
		end
	end
end

return PartyMenu
