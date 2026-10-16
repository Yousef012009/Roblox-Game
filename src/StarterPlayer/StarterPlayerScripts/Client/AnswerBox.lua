--!strict
--[[
	AnswerBox  (ModuleScript)  ·  StarterPlayerScripts/Client/AnswerBox

	The local player's answer input, shown only on their own turn. Floats at
	the bottom centre; while the TextBox is focused it jumps to the top half
	(under the HUD) because phone keyboards cover the bottom of the screen.

	One submission per turn: disabled after sending, re-enabled only by an
	InputRejected for this same turn (the timer keeps running server-side).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AnswerRules = require(ReplicatedStorage.Shared.AnswerRules)
local Config = require(ReplicatedStorage.Shared.Config)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local State = require(script.Parent.State)
local UIKit = require(script.Parent.UIKit)

local AnswerBox = {}

local HEIGHT = 124
local REST_ANCHOR = Vector2.new(0.5, 1)
local REST_POSITION = UDim2.new(0.5, 0, 1, -10)
local FOCUS_ANCHOR = Vector2.new(0.5, 0)
local FOCUS_POSITION = UDim2.new(0.5, 0, 0, UIKit.Layout.BelowHud) -- under the GameHUD + metronome

local root: Frame
local headerLabel: TextLabel
local timerLabel: TextLabel
local timeFill: Frame
local box: TextBox
local sendButton: TextButton
local errorLabel: TextLabel
local visible = false
local turnId: number? = nil -- turn this box is open for
local sentTurnId: number? = nil
local lastSeconds = -1
local lastFrac = -1
local onFocusChanged: ((boolean) -> ())? = nil

local function setError(text: string)
	UIKit.setText(errorLabel, string.upper(text))
end

local function setLocked(locked: boolean)
	box.TextEditable = not locked
	UIKit.setEnabled(sendButton, not locked)
	UIKit.setText(sendButton, if locked then "SENT" else "SEND")
end

local function submit()
	local matchId = State.matchId()
	local id = turnId
	if not visible or not matchId or id == nil or sentTurnId == id or not State.isMyTurn() then
		return
	end
	local ok, result = AnswerRules.validateAnswer(box.Text)
	if not ok then
		setError(result)
		return
	end
	sentTurnId = id
	setError("")
	setLocked(true)
	Remotes.SubmitAnswer:FireServer(matchId, id, result)
	if box:IsFocused() then
		box:ReleaseFocus()
	end
end

local function placeForFocus(focused: boolean)
	root.AnchorPoint = if focused then FOCUS_ANCHOR else REST_ANCHOR
	root.Position = if focused then FOCUS_POSITION else REST_POSITION
end

function AnswerBox.mount(parent: Instance, focusCallback: (boolean) -> ())
	onFocusChanged = focusCallback
	root = UIKit.panel({
		Name = "AnswerBox",
		AnchorPoint = REST_ANCHOR,
		Position = REST_POSITION,
		Size = UDim2.new(0.94, 0, 0, HEIGHT),
		Visible = false,
		ZIndex = 20,
		Parent = parent,
	})
	UIKit.sizeLimit(Vector2.new(0, 0), Vector2.new(560, HEIGHT)).Parent = root
	UIKit.padding(8).Parent = root

	headerLabel = UIKit.label({
		Text = "YOUR TURN",
		Font = UIKit.Fonts.Header,
		TextColor3 = UIKit.Colors.Phosphor,
		TextXAlignment = Enum.TextXAlignment.Left,
		Size = UDim2.new(1, -64, 0, 22),
		ZIndex = 21,
		Parent = root,
	}, 20)
	timerLabel = UIKit.label({
		TextXAlignment = Enum.TextXAlignment.Right,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(1, 0),
		Size = UDim2.fromOffset(60, 22),
		ZIndex = 21,
		Parent = root,
	}, 20)
	local bar = UIKit.new("Frame", {
		BorderSizePixel = 0,
		BackgroundColor3 = UIKit.Colors.PanelLight,
		Position = UDim2.fromOffset(0, 25),
		Size = UDim2.new(1, 0, 0, 3),
		ZIndex = 21,
		Parent = root,
	})
	timeFill = UIKit.new("Frame", {
		BorderSizePixel = 0,
		BackgroundColor3 = UIKit.Colors.Phosphor,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 22,
		Parent = bar,
	})

	box = UIKit.new("TextBox", {
		Name = "AnswerInput",
		BackgroundColor3 = UIKit.Colors.Black,
		BackgroundTransparency = 0.25,
		BorderSizePixel = 0,
		ClearTextOnFocus = false,
		Font = UIKit.Fonts.Body,
		PlaceholderText = "TYPE YOUR ANSWER",
		PlaceholderColor3 = UIKit.Colors.TextFaint,
		TextColor3 = UIKit.Colors.Text,
		TextScaled = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = "",
		Position = UDim2.fromOffset(0, 34),
		Size = UDim2.new(1, -100, 0, 52),
		ZIndex = 21,
		Parent = root,
	}, {
		UIKit.stroke(UIKit.Colors.PhosphorDim, 1, 0),
		UIKit.padding(8),
		UIKit.new("UITextSizeConstraint", { MaxTextSize = 26, MinTextSize = 12 }),
	})
	box:GetPropertyChangedSignal("Text"):Connect(function()
		local capped = AnswerRules.truncate(box.Text, Config.Text.AnswerMaxLength)
		if capped ~= box.Text then
			box.Text = capped
		end
	end)
	box.Focused:Connect(function()
		placeForFocus(true)
		if onFocusChanged then
			onFocusChanged(true)
		end
	end)
	box.FocusLost:Connect(function(enterPressed: boolean)
		placeForFocus(false)
		if onFocusChanged then
			onFocusChanged(false)
		end
		if enterPressed then
			submit()
		end
	end)

	sendButton = UIKit.button({
		Text = "SEND",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, 0, 0, 34),
		Size = UDim2.fromOffset(92, 52),
		ZIndex = 21,
		Parent = root,
	}, UIKit.Colors.Phosphor, 22)
	sendButton.Activated:Connect(submit)

	errorLabel = UIKit.label({
		TextColor3 = UIKit.Colors.Red,
		TextXAlignment = Enum.TextXAlignment.Left,
		Position = UDim2.fromOffset(0, 90),
		Size = UDim2.new(1, 0, 0, 18),
		ZIndex = 21,
		Parent = root,
	}, 14)
end

-- Opens the box for `id` (a new turn of the local player).
function AnswerBox.open(id: number)
	if visible and turnId == id then
		return
	end
	turnId = id
	visible = true
	lastSeconds = -1
	box.Text = ""
	setError("")
	setLocked(sentTurnId == id)
	placeForFocus(false)
	UIKit.reveal(root, 12)
	-- CaptureFocus at turn start: on phones this raises the keyboard at once.
	task.defer(function()
		if visible and turnId == id and sentTurnId ~= id then
			box:CaptureFocus()
		end
	end)
end

function AnswerBox.close()
	if not visible then
		return
	end
	visible = false
	turnId = nil
	if box:IsFocused() then
		box:ReleaseFocus()
	end
	placeForFocus(false)
	root.Visible = false
end

function AnswerBox.onRejected(reason: string)
	if not visible or turnId == nil or not State.isMyTurn() then
		return
	end
	sentTurnId = nil
	setLocked(false)
	setError(reason)
	box:CaptureFocus()
end

function AnswerBox.step()
	local snapshot = State.snapshot
	local turn = snapshot and snapshot.turn
	if not visible or not turn then
		return
	end
	local now = State.now()
	local remaining = turn.endsAt - now
	local seconds = math.max(0, math.ceil(remaining))
	if seconds ~= lastSeconds then
		lastSeconds = seconds
		timerLabel.Text = UIKit.clock(seconds)
		timerLabel.TextColor3 = if seconds <= 2 then UIKit.Colors.Red else UIKit.Colors.Text
		if seconds <= 2 and seconds > 0 then
			UIKit.pulse(timerLabel, 1.4, 0.35)
		end
		UIKit.setText(headerLabel, if sentTurnId == turnId then "ANSWER SENT" else "YOUR TURN")
	end
	local total = turn.endsAt - turn.startsAt
	-- Quantised to 1/100 so the bar only updates when it visibly moves.
	local frac = if total > 0 then math.floor(math.clamp(remaining / total, 0, 1) * 100) / 100 else 0
	if frac ~= lastFrac then
		lastFrac = frac
		timeFill.Size = UDim2.fromScale(frac, 1)
	end
end

return AnswerBox
