--!strict
--[[
	VictoryScreen  (ModuleScript)  ·  StarterPlayerScripts/Client/VictoryScreen

	ROUND_END: the round winner. GAME_END: the winner(s) (shared win listed
	together), a red "CASE CLOSED" stamp that slams onto the file, and the
	standings: round wins / accepted answers per participant. Up to 8 rows
	(Config.Queue.Capacity) in a scrolling list so it fits a landscape phone;
	bots are tagged "AI". A countdown to the next phase sits in the footer.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local State = require(script.Parent.State)
local UIKit = require(script.Parent.UIKit)

local VictoryScreen = {}

local MAX_ROWS = Config.Queue.Capacity
local ROW_HEIGHT = 24
local HEADER_HEIGHT = 76
local FOOTER_HEIGHT = 20
local STAMP_IN = TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.In)

type Row = { frame: Frame, name: TextLabel, stats: TextLabel }

local root: Frame
local titleLabel: TextLabel
local winnerLabel: TextLabel
local list: ScrollingFrame
local rows: { Row } = {}
local footer: TextLabel
local stamp: TextLabel
local stampScale: UIScale
local visible = false
local lastSeconds = -1
local stampedMatch: string? = nil
local sortBuffer: { State.MatchPlayer } = {}
local onStamp: (() -> ())? = nil

function VictoryScreen.mount(parent: Instance, stampCallback: (() -> ())?)
	onStamp = stampCallback
	root = UIKit.panel({
		Name = "VictoryScreen",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.new(0.92, 0, 1, -16),
		Visible = false,
		ZIndex = 25,
		Parent = parent,
	})
	UIKit.sizeLimit(Vector2.new(0, 0), Vector2.new(500, HEADER_HEIGHT + FOOTER_HEIGHT + MAX_ROWS * (ROW_HEIGHT + 2) + 30)).Parent =
		root
	UIKit.padding(12).Parent = root

	titleLabel = UIKit.label({
		TextColor3 = UIKit.Colors.TextDim,
		Size = UDim2.new(1, 0, 0, 20),
		ZIndex = 26,
		Parent = root,
	}, 16)
	winnerLabel = UIKit.label({
		Font = UIKit.Fonts.Header,
		TextColor3 = UIKit.Colors.Phosphor,
		Position = UDim2.fromOffset(0, 22),
		Size = UDim2.new(1, 0, 0, 46),
		ZIndex = 26,
		Parent = root,
	}, 40, 12)
	UIKit.new("Frame", {
		BorderSizePixel = 0,
		BackgroundColor3 = UIKit.Colors.Border,
		Position = UDim2.fromOffset(0, HEADER_HEIGHT - 4),
		Size = UDim2.new(1, 0, 0, 1),
		ZIndex = 26,
		Parent = root,
	})
	list = UIKit.new("ScrollingFrame", {
		Name = "Standings",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(0, HEADER_HEIGHT),
		Size = UDim2.new(1, 0, 1, -(HEADER_HEIGHT + FOOTER_HEIGHT + 2)),
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		ScrollBarThickness = 4,
		ScrollBarImageColor3 = UIKit.Colors.Border,
		ZIndex = 26,
		Parent = root,
	}, {
		UIKit.new("UIListLayout", {
			FillDirection = Enum.FillDirection.Vertical,
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, 2),
		}),
	})
	for i = 1, MAX_ROWS do
		local frame = UIKit.new("Frame", {
			Name = `Row{i}`,
			BackgroundTransparency = 1,
			LayoutOrder = i,
			Size = UDim2.new(1, -6, 0, ROW_HEIGHT),
			Visible = false,
			ZIndex = 26,
			Parent = list,
		})
		local name = UIKit.label({
			RichText = true,
			TextXAlignment = Enum.TextXAlignment.Left,
			Size = UDim2.new(0.62, 0, 1, 0),
			ZIndex = 27,
			Parent = frame,
		}, 17, 8)
		local stats = UIKit.label({
			TextXAlignment = Enum.TextXAlignment.Right,
			TextColor3 = UIKit.Colors.TextDim,
			Position = UDim2.fromScale(0.62, 0),
			Size = UDim2.new(0.38, 0, 1, 0),
			ZIndex = 27,
			Parent = frame,
		}, 15, 8)
		table.insert(rows, { frame = frame, name = name, stats = stats })
	end
	footer = UIKit.label({
		TextColor3 = UIKit.Colors.TextFaint,
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.fromScale(0, 1),
		Size = UDim2.new(1, 0, 0, 18),
		ZIndex = 26,
		Parent = root,
	}, 14)

	stamp = UIKit.label({
		Name = "CaseClosedStamp",
		Text = "CASE CLOSED",
		Font = UIKit.Fonts.Header,
		TextColor3 = UIKit.Colors.Red,
		BackgroundColor3 = UIKit.Colors.RedDim,
		BackgroundTransparency = 0.85,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(1, -78, 0, 18),
		Size = UDim2.fromOffset(170, 46),
		Rotation = -12,
		Visible = false,
		ZIndex = 30,
		Parent = root,
	}, 30, 12)
	UIKit.stroke(UIKit.Colors.Red, 3, 0).Parent = stamp
	stampScale = UIKit.scaleOf(stamp)
end

local function winnersText(ids: { number }): string
	local names = table.create(#ids)
	for i, id in ids do
		names[i] = State.tagName(id)
	end
	return table.concat(names, " & ")
end

local function fillStandings(winnerSet: { [number]: boolean })
	table.clear(sortBuffer)
	local snapshot = State.snapshot
	local players: { State.MatchPlayer } = if snapshot and type(snapshot.players) == "table" then snapshot.players else {}
	for _, player in players do
		table.insert(sortBuffer, player)
	end
	table.sort(sortBuffer, function(a, b)
		local aw, bw = a.roundWins or 0, b.roundWins or 0
		if aw ~= bw then
			return aw > bw
		end
		local aa, ba = a.acceptedCount or 0, b.acceptedCount or 0
		if aa ~= ba then
			return aa > ba
		end
		return (a.seat or 0) < (b.seat or 0)
	end)
	for i, row in rows do
		local player = sortBuffer[i]
		if player then
			local isWinner = winnerSet[player.userId] == true
			local tag = if player.isBot then ` <font color="#d2a85c">AI</font>` else ""
			local you = if player.userId == State.localUserId then "  (YOU)" else ""
			local name = UIKit.escape(string.upper(player.name or "?"))
			UIKit.setText(row.name, `{i}. {name}{tag}{you}`)
			row.name.TextColor3 = if isWinner then UIKit.Colors.Phosphor else UIKit.Colors.Text
			local wins = player.roundWins or 0
			local accepted = player.acceptedCount or 0
			UIKit.setText(row.stats, `{wins} WIN{if wins == 1 then "" else "S"} · {accepted} ANS`)
			row.frame.Visible = true
		else
			row.frame.Visible = false
		end
	end
end

-- Slams the stamp once per match (GAME_END).
local function playStamp(matchId: string)
	if stampedMatch == matchId then
		stamp.Visible = true
		return
	end
	stampedMatch = matchId
	stamp.Visible = true
	stamp.TextTransparency = 1
	stampScale.Scale = 2.6
	UIKit.tween(stamp, STAMP_IN, { TextTransparency = 0 })
	local slam = UIKit.tween(stampScale, STAMP_IN, { Scale = 1 })
	slam.Completed:Connect(function(playbackState: Enum.PlaybackState)
		if playbackState == Enum.PlaybackState.Completed and visible then
			UIKit.pulse(root, 1.03, 0.25)
			local callback = onStamp
			if callback then
				callback()
			end
		end
	end)
end

function VictoryScreen.update()
	local snapshot = State.snapshot
	if not visible or not snapshot then
		return
	end
	lastSeconds = -1
	local winnerSet: { [number]: boolean } = {}
	if snapshot.state == "GAME_END" then
		local winners: { number } = snapshot.winnerUserIds or {}
		for _, id in winners do
			winnerSet[id] = true
		end
		UIKit.setText(titleLabel, if #winners > 1 then "VERDICT  ·  SHARED WIN" else "VERDICT  ·  WINNER")
		UIKit.setText(winnerLabel, if #winners > 0 then winnersText(winners) else "NO WINNER")
		playStamp(snapshot.matchId)
	else
		stamp.Visible = false
		local id = snapshot.roundWinnerUserId
		if id then
			winnerSet[id] = true
		end
		UIKit.setText(titleLabel, `ROUND {snapshot.round or 1}/{snapshot.totalRounds or 1}  ·  LAST ONE STANDING`)
		UIKit.setText(winnerLabel, if id then State.tagName(id) else "NO WINNER")
	end
	winnerLabel.TextColor3 = if winnerSet[State.localUserId] then UIKit.Colors.Amber else UIKit.Colors.Phosphor
	fillStandings(winnerSet)
end

function VictoryScreen.setVisible(on: boolean)
	if on == visible then
		if on then
			VictoryScreen.update()
		end
		return
	end
	visible = on
	if on then
		VictoryScreen.update()
		UIKit.reveal(root, 16)
	else
		root.Visible = false
		stamp.Visible = false
	end
end

function VictoryScreen.step()
	local snapshot = State.snapshot
	if not visible or not snapshot then
		return
	end
	local endsAt = snapshot.stateEndsAt
	local seconds = if endsAt then math.max(0, math.ceil(endsAt - State.now())) else -1
	if seconds ~= lastSeconds then
		lastSeconds = seconds
		local next = if snapshot.state == "GAME_END" then "RETURNING TO LOBBY" else "NEXT ROUND"
		footer.Text = if seconds >= 0 then `{next} IN {UIKit.clock(seconds)}` else next
	end
end

return VictoryScreen
