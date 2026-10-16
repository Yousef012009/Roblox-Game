--!strict
--[[
	VictoryScreen  (ModuleScript)  ·  StarterPlayerScripts/Client/VictoryScreen

	ROUND_END: the round winner. GAME_END: the winner(s) (shared win listed
	together) and the standings: round wins / accepted answers per player.
	A countdown to the next phase sits in the footer.
]]

local State = require(script.Parent.State)
local UIKit = require(script.Parent.UIKit)

local VictoryScreen = {}

local MAX_ROWS = 4

type Row = { frame: Frame, name: TextLabel, stats: TextLabel }

local root: Frame
local titleLabel: TextLabel
local winnerLabel: TextLabel
local rows: { Row } = {}
local footer: TextLabel
local visible = false
local lastSeconds = -1
local sortBuffer: { State.MatchPlayer } = {}

function VictoryScreen.mount(parent: Instance)
	root = UIKit.panel({
		Name = "VictoryScreen",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.new(0.92, 0, 0, 262),
		Visible = false,
		ZIndex = 25,
		Parent = parent,
	})
	UIKit.sizeLimit(Vector2.new(0, 0), Vector2.new(500, 262)).Parent = root
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
		Size = UDim2.new(1, 0, 0, 50),
		ZIndex = 26,
		Parent = root,
	}, 42, 14)
	UIKit.new("Frame", {
		BorderSizePixel = 0,
		BackgroundColor3 = UIKit.Colors.Border,
		Position = UDim2.fromOffset(0, 78),
		Size = UDim2.new(1, 0, 0, 1),
		ZIndex = 26,
		Parent = root,
	})
	for i = 1, MAX_ROWS do
		local frame = UIKit.new("Frame", {
			BackgroundTransparency = 1,
			Position = UDim2.fromOffset(0, 84 + (i - 1) * 32),
			Size = UDim2.new(1, 0, 0, 30),
			Visible = false,
			ZIndex = 26,
			Parent = root,
		})
		local name = UIKit.label({
			TextXAlignment = Enum.TextXAlignment.Left,
			Size = UDim2.new(0.6, 0, 1, 0),
			ZIndex = 27,
			Parent = frame,
		}, 18)
		local stats = UIKit.label({
			TextXAlignment = Enum.TextXAlignment.Right,
			TextColor3 = UIKit.Colors.TextDim,
			Position = UDim2.fromScale(0.6, 0),
			Size = UDim2.new(0.4, 0, 1, 0),
			ZIndex = 27,
			Parent = frame,
		}, 16)
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
end

local function winnersText(ids: { number }): string
	local names = table.create(#ids)
	for i, id in ids do
		names[i] = string.upper(State.nameOf(id))
	end
	return table.concat(names, " & ")
end

local function fillStandings(winnerSet: { [number]: boolean })
	table.clear(sortBuffer)
	local snapshot = State.snapshot
	local players: { State.MatchPlayer } = if snapshot and snapshot.players then snapshot.players else {}
	for _, player in players do
		table.insert(sortBuffer, player)
	end
	table.sort(sortBuffer, function(a, b)
		if a.roundWins ~= b.roundWins then
			return a.roundWins > b.roundWins
		end
		if a.acceptedCount ~= b.acceptedCount then
			return a.acceptedCount > b.acceptedCount
		end
		return a.seat < b.seat
	end)
	for i, row in rows do
		local player = sortBuffer[i]
		if player then
			local isWinner = winnerSet[player.userId] == true
			local you = if player.userId == State.localUserId then "  (YOU)" else ""
			UIKit.setText(row.name, `{i}. {string.upper(player.name)}{you}`)
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
		UIKit.setText(titleLabel, if #winners > 1 then "CASE CLOSED  ·  SHARED VERDICT" else "CASE CLOSED  ·  WINNER")
		UIKit.setText(winnerLabel, if #winners > 0 then winnersText(winners) else "NO WINNER")
	else
		local id = snapshot.roundWinnerUserId
		if id then
			winnerSet[id] = true
		end
		UIKit.setText(titleLabel, `ROUND {snapshot.round or 1}/{snapshot.totalRounds or 1}  ·  LAST ONE STANDING`)
		UIKit.setText(winnerLabel, if id then string.upper(State.nameOf(id)) else "NO WINNER")
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
