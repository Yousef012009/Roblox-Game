--!strict
--[[
	GameHUD  (ModuleScript)  ·  StarterPlayerScripts/Client/GameHUD

	Top bar during play:
	  row 1  ROUND r/R · CATEGORY · musical timer (seconds left)
	  row 2  who is answering now
	  row 3  turn-order strip: answerers in snapshot.turnOrder (eliminated
	         struck through in red, current highlighted) + the Caller chip
	  row 4  beat bar: fraction of the current turn's beats elapsed
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MusicTimeline = require(ReplicatedStorage.Shared.MusicTimeline)
local MusicController = require(script.Parent.MusicController)
local State = require(script.Parent.State)
local UIKit = require(script.Parent.UIKit)

local GameHUD = {}

local MAX_CHIPS = 5 -- 3 answerers + Caller at capacity 4, one spare

local root: Frame
local roundLabel: TextLabel
local categoryLabel: TextLabel
local timerLabel: TextLabel
local nowLabel: TextLabel
local chips: { TextLabel } = {}
local beatFill: Frame
local visible = false
local lastSeconds = -1
local lastFill = -1

local function escape(text: string): string
	local escaped = string.gsub(text, "&", "&amp;")
	escaped = string.gsub(escaped, "<", "&lt;")
	escaped = string.gsub(escaped, ">", "&gt;")
	return escaped
end

function GameHUD.mount(parent: Instance)
	root = UIKit.panel({
		Name = "GameHUD",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 4),
		Size = UDim2.new(0.97, 0, 0, 86),
		Visible = false,
		ZIndex = 5,
		Parent = parent,
	})
	UIKit.sizeLimit(Vector2.new(0, 0), Vector2.new(900, 86)).Parent = root

	roundLabel = UIKit.label({
		TextColor3 = UIKit.Colors.TextDim,
		TextXAlignment = Enum.TextXAlignment.Left,
		Position = UDim2.fromOffset(8, 4),
		Size = UDim2.new(0.22, -8, 0, 22),
		ZIndex = 6,
		Parent = root,
	}, 15)
	categoryLabel = UIKit.label({
		Font = UIKit.Fonts.Header,
		TextColor3 = UIKit.Colors.Phosphor,
		Position = UDim2.new(0.22, 0, 0, 2),
		Size = UDim2.new(0.56, 0, 0, 26),
		ZIndex = 6,
		Parent = root,
	}, 22, 10)
	timerLabel = UIKit.label({
		Font = UIKit.Fonts.Body,
		TextXAlignment = Enum.TextXAlignment.Right,
		Position = UDim2.new(0.78, 0, 0, 2),
		Size = UDim2.new(0.22, -8, 0, 26),
		ZIndex = 6,
		Parent = root,
	}, 24)
	nowLabel = UIKit.label({
		TextColor3 = UIKit.Colors.Text,
		Position = UDim2.fromOffset(8, 30),
		Size = UDim2.new(1, -16, 0, 20),
		ZIndex = 6,
		Parent = root,
	}, 16)

	local strip = UIKit.new("Frame", {
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(6, 53),
		Size = UDim2.new(1, -12, 0, 24),
		ZIndex = 6,
		Parent = root,
	}, {
		UIKit.new("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal,
			HorizontalAlignment = Enum.HorizontalAlignment.Center,
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, 4),
		}),
	})
	for i = 1, MAX_CHIPS do
		local chip = UIKit.label({
			Name = `Chip{i}`,
			RichText = true,
			LayoutOrder = i,
			BackgroundColor3 = UIKit.Colors.PanelLight,
			BackgroundTransparency = 0.3,
			Size = UDim2.new(1 / MAX_CHIPS, -4, 1, 0),
			Visible = false,
			ZIndex = 7,
			Parent = strip,
		}, 14, 8)
		UIKit.stroke(UIKit.Colors.Border, 1, 0.5).Parent = chip
		table.insert(chips, chip)
	end

	local bar = UIKit.new("Frame", {
		BorderSizePixel = 0,
		BackgroundColor3 = UIKit.Colors.PanelLight,
		Position = UDim2.new(0, 6, 1, -6),
		Size = UDim2.new(1, -12, 0, 3),
		ZIndex = 6,
		Parent = root,
	})
	beatFill = UIKit.new("Frame", {
		BorderSizePixel = 0,
		BackgroundColor3 = UIKit.Colors.Phosphor,
		Size = UDim2.fromScale(0, 1),
		ZIndex = 7,
		Parent = bar,
	})
end

local function setChip(chip: TextLabel, text: string, color: Color3, strokeColor: Color3, bold: boolean)
	local rich = if bold then `<b>{text}</b>` else text
	UIKit.setText(chip, rich)
	chip.TextColor3 = color
	local stroke = chip:FindFirstChildOfClass("UIStroke")
	if stroke then
		stroke.Color = strokeColor
		stroke.Transparency = if bold then 0 else 0.5
	end
	UIKit.setVisible(chip, true)
end

-- Rebuilds texts from the snapshot (called on snapshot change only).
function GameHUD.update()
	local snapshot = State.snapshot
	if not snapshot then
		return
	end
	lastSeconds = -1
	UIKit.setText(roundLabel, `ROUND {snapshot.round or 1}/{snapshot.totalRounds or 1}`)
	UIKit.setText(categoryLabel, if snapshot.category then string.upper(snapshot.category) else "CATEGORY PENDING")

	local turn = snapshot.turn
	local judging = snapshot.judging
	local nowText
	if snapshot.state == "JUDGING" and judging then
		nowText = `{string.upper(State.nameOf(judging.userId))} SAID "{judging.answer}"`
	elseif turn then
		nowText = if turn.userId == State.localUserId
			then "YOUR TURN - ANSWER NOW"
			else `NOW ANSWERING: {string.upper(State.nameOf(turn.userId))}`
	elseif snapshot.state == "COUNTDOWN" then
		nowText = "LISTEN TO THE BEAT..."
	else
		nowText = ""
	end
	UIKit.setText(nowLabel, nowText)

	local currentId = if turn then turn.userId elseif judging then judging.userId else nil
	local index = 0
	local order: { number } = snapshot.turnOrder or {}
	for _, userId in order do
		index += 1
		local chip = chips[index]
		if not chip then
			break
		end
		local player = State.playersById[userId]
		local name = escape(string.upper(State.nameOf(userId)))
		local out = player ~= nil and player.status ~= "Active"
		if out then
			setChip(chip, `<s>{name}</s>`, UIKit.Colors.Red, UIKit.Colors.RedDim, false)
		elseif userId == currentId then
			setChip(chip, `▶ {name}`, UIKit.Colors.Phosphor, UIKit.Colors.Phosphor, true)
		else
			setChip(chip, name, UIKit.Colors.Text, UIKit.Colors.Border, false)
		end
	end
	local callerId = snapshot.callerUserId
	if callerId and index < MAX_CHIPS then
		index += 1
		local name = escape(string.upper(State.nameOf(callerId)))
		setChip(chips[index], `CALLER · {name}`, UIKit.Colors.Amber, UIKit.Colors.Amber, false)
	end
	for i = index + 1, MAX_CHIPS do
		UIKit.setVisible(chips[i], false)
	end
end

function GameHUD.setVisible(on: boolean)
	if on and not visible then
		visible = true
		GameHUD.update()
		UIKit.reveal(root, -8)
	elseif not on and visible then
		visible = false
		root.Visible = false
	end
end

local function deadline(): number?
	local snapshot = State.snapshot
	if not snapshot then
		return nil
	end
	if snapshot.state == "PLAYING" and snapshot.turn then
		return snapshot.turn.endsAt
	elseif snapshot.state == "JUDGING" and snapshot.judging then
		return snapshot.judging.deadline
	end
	return snapshot.stateEndsAt
end

-- Timer text once per second; beat bar only when it moves visibly.
function GameHUD.step()
	if not visible then
		return
	end
	local snapshot = State.snapshot
	local now = State.now()
	local endsAt = deadline()
	local seconds = if endsAt then math.max(0, math.ceil(endsAt - now)) else -1
	if seconds ~= lastSeconds then
		lastSeconds = seconds
		timerLabel.Text = if seconds >= 0 then UIKit.clock(seconds) else ""
		timerLabel.TextColor3 = if seconds >= 0 and seconds <= 2 then UIKit.Colors.Red else UIKit.Colors.Text
	end

	local fill = 0
	local turn = if snapshot and snapshot.state == "PLAYING" then snapshot.turn else nil
	if turn then
		local beat = MusicController.currentBeat()
		local span = turn.endBeat - turn.startBeat
		if beat ~= nil and span > 0 then
			fill = (beat - turn.startBeat) / span
		elseif turn.endsAt > turn.startsAt then
			fill = (now - turn.startsAt) / (turn.endsAt - turn.startsAt)
		end
		-- Quantise to whole beats of the turn so the bar ticks with the music.
		if span > 0 then
			fill = math.floor(math.clamp(fill, 0, 1) * span) / span
		end
	elseif snapshot and snapshot.state == "COUNTDOWN" then
		local beat = MusicController.currentBeat()
		if beat ~= nil then
			fill = math.floor(math.max(beat, 0)) / MusicTimeline.LoopStartBeat
		end
	end
	fill = math.clamp(fill, 0, 1)
	if math.abs(fill - lastFill) > 0.001 then
		lastFill = fill
		beatFill.Size = UDim2.fromScale(fill, 1)
		beatFill.BackgroundColor3 = if fill >= 0.75 and turn then UIKit.Colors.Red else UIKit.Colors.Phosphor
	end
end

return GameHUD
