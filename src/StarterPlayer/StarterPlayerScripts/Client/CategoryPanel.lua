--!strict
--[[
	CategoryPanel  (ModuleScript)  ·  StarterPlayerScripts/Client/CategoryPanel

	Caller only, CATEGORY_SELECTION: "YOU ARE THE CALLER - NAME A CATEGORY",
	a large TextBox, SUBMIT and a countdown. Enter (FocusLost enterPressed)
	submits too. Validated locally with AnswerRules.validateCategory; the
	server's InputRejected reasons are shown under the box. The panel sits in
	the top half of the screen so phone keyboards never cover it.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AnswerRules = require(ReplicatedStorage.Shared.AnswerRules)
local Config = require(ReplicatedStorage.Shared.Config)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local State = require(script.Parent.State)
local UIKit = require(script.Parent.UIKit)

local CategoryPanel = {}

local root: Frame
local box: TextBox
local submitButton: TextButton
local timerLabel: TextLabel
local errorLabel: TextLabel
local visible = false
local submittedFor: string? = nil -- matchId we already submitted for (awaiting server)
local lastSeconds = -1
local onFocusChanged: ((boolean) -> ())? = nil

local function setError(text: string)
	UIKit.setText(errorLabel, string.upper(text))
end

local function submit()
	local matchId = State.matchId()
	if not visible or not matchId or submittedFor == matchId then
		return
	end
	local ok, result = AnswerRules.validateCategory(box.Text)
	if not ok then
		setError(result)
		return
	end
	submittedFor = matchId
	setError("")
	UIKit.setEnabled(submitButton, false)
	box.TextEditable = false
	UIKit.setText(submitButton, "SENT")
	Remotes.SubmitCategory:FireServer(matchId, result)
end

function CategoryPanel.mount(parent: Instance, focusCallback: (boolean) -> ())
	onFocusChanged = focusCallback
	root = UIKit.panel({
		Name = "CategoryPanel",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 8),
		Size = UDim2.new(0.94, 0, 0, 168),
		Visible = false,
		ZIndex = 12,
		Parent = parent,
	})
	UIKit.sizeLimit(Vector2.new(0, 0), Vector2.new(580, 168)).Parent = root
	UIKit.padding(10).Parent = root

	UIKit.label({
		Text = "YOU ARE THE CALLER - NAME A CATEGORY",
		Font = UIKit.Fonts.Header,
		TextColor3 = UIKit.Colors.Phosphor,
		TextXAlignment = Enum.TextXAlignment.Left,
		Size = UDim2.new(1, -60, 0, 26),
		ZIndex = 13,
		Parent = root,
	}, 22, 11)
	timerLabel = UIKit.label({
		TextColor3 = UIKit.Colors.Phosphor,
		TextXAlignment = Enum.TextXAlignment.Right,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(1, 0),
		Size = UDim2.fromOffset(56, 26),
		ZIndex = 13,
		Parent = root,
	}, 20)

	box = UIKit.new("TextBox", {
		Name = "CategoryBox",
		BackgroundColor3 = UIKit.Colors.Black,
		BackgroundTransparency = 0.25,
		BorderSizePixel = 0,
		ClearTextOnFocus = false,
		Font = UIKit.Fonts.Body,
		PlaceholderText = "e.g. THINGS FOUND IN A CRIME SCENE",
		PlaceholderColor3 = UIKit.Colors.TextFaint,
		TextColor3 = UIKit.Colors.Text,
		TextScaled = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = "",
		Position = UDim2.fromOffset(0, 32),
		Size = UDim2.new(1, 0, 0, 52),
		ZIndex = 13,
		Parent = root,
	}, {
		UIKit.stroke(UIKit.Colors.PhosphorDim, 1, 0),
		UIKit.padding(8),
		UIKit.new("UITextSizeConstraint", { MaxTextSize = 24, MinTextSize = 12 }),
	})
	box:GetPropertyChangedSignal("Text"):Connect(function()
		-- Hard cap so the box can't grow unboundedly; the server validates again.
		local capped = AnswerRules.truncate(box.Text, Config.Text.CategoryMaxLength)
		if capped ~= box.Text then
			box.Text = capped
		end
	end)
	box.Focused:Connect(function()
		if onFocusChanged then
			onFocusChanged(true)
		end
	end)
	box.FocusLost:Connect(function(enterPressed: boolean)
		if onFocusChanged then
			onFocusChanged(false)
		end
		if enterPressed then
			submit()
		end
	end)

	submitButton = UIKit.button({
		Text = "SUBMIT",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, 0, 0, 92),
		Size = UDim2.fromOffset(128, UIKit.TouchMin),
		ZIndex = 13,
		Parent = root,
	}, UIKit.Colors.Phosphor, 20)
	submitButton.Activated:Connect(submit)

	errorLabel = UIKit.label({
		TextColor3 = UIKit.Colors.Red,
		TextXAlignment = Enum.TextXAlignment.Left,
		Position = UDim2.fromOffset(0, 92),
		Size = UDim2.new(1, -140, 0, 44),
		ZIndex = 13,
		Parent = root,
	}, 14)
end

function CategoryPanel.show()
	if visible then
		return
	end
	visible = true
	lastSeconds = -1
	if submittedFor ~= State.matchId() then
		submittedFor = nil
		box.Text = ""
		box.TextEditable = true
		setError("")
		UIKit.setText(submitButton, "SUBMIT")
		UIKit.setEnabled(submitButton, true)
	end
	UIKit.reveal(root, 10)
	-- Opens the on-screen keyboard on phones; harmless on desktop.
	task.defer(function()
		if visible and submittedFor == nil then
			box:CaptureFocus()
		end
	end)
end

function CategoryPanel.hide()
	if not visible then
		return
	end
	visible = false
	if box:IsFocused() then
		box:ReleaseFocus()
	end
	root.Visible = false
end

-- A new round's category selection must accept input again.
function CategoryPanel.reset()
	submittedFor = nil
end

function CategoryPanel.onRejected(reason: string)
	if not visible then
		return
	end
	submittedFor = nil
	box.TextEditable = true
	UIKit.setText(submitButton, "SUBMIT")
	UIKit.setEnabled(submitButton, true)
	setError(reason)
end

function CategoryPanel.step()
	local snapshot = State.snapshot
	if not visible or not snapshot then
		return
	end
	local endsAt = snapshot.stateEndsAt
	local seconds = if endsAt then math.max(0, math.ceil(endsAt - State.now())) else -2
	if seconds ~= lastSeconds then
		lastSeconds = seconds
		timerLabel.Text = if seconds >= 0 then UIKit.clock(seconds) else ""
		timerLabel.TextColor3 = if seconds >= 0 and seconds <= 10 then UIKit.Colors.Red else UIKit.Colors.Phosphor
	end
end

return CategoryPanel
