--!strict
--[[
	JudgePanel  (ModuleScript)  ·  StarterPlayerScripts/Client/JudgePanel

	Caller only, JUDGING: the answer, who said it, the category, the judging
	countdown, and two large buttons: VALID (muted green) and
	GIBBERISH / WRONG (red). The first tap sends JudgeAnswer and locks both.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Remotes = require(ReplicatedStorage.Shared.Remotes)
local State = require(script.Parent.State)
local UIKit = require(script.Parent.UIKit)

local JudgePanel = {}

local root: Frame
local headerLabel: TextLabel
local timerLabel: TextLabel
local whoLabel: TextLabel
local answerLabel: TextLabel
local validButton: TextButton
local wrongButton: TextButton
local visible = false
local turnId: number? = nil
local judgedTurnId: number? = nil
local lastSeconds = -1

local function judge(verdict: "Valid" | "Wrong")
	local matchId = State.matchId()
	local id = turnId
	if not visible or not matchId or id == nil or judgedTurnId == id then
		return
	end
	judgedTurnId = id
	UIKit.setEnabled(validButton, false)
	UIKit.setEnabled(wrongButton, false)
	UIKit.setText(headerLabel, if verdict == "Valid" then "MARKED VALID" else "MARKED GIBBERISH")
	Remotes.JudgeAnswer:FireServer(matchId, id, verdict)
end

function JudgePanel.mount(parent: Instance)
	root = UIKit.panel({
		Name = "JudgePanel",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 122),
		Size = UDim2.new(0.94, 0, 0, 196),
		Visible = false,
		ZIndex = 20,
		Parent = parent,
	})
	UIKit.sizeLimit(Vector2.new(0, 0), Vector2.new(560, 196)).Parent = root
	UIKit.padding(10).Parent = root

	headerLabel = UIKit.label({
		Font = UIKit.Fonts.Header,
		TextColor3 = UIKit.Colors.Amber,
		TextXAlignment = Enum.TextXAlignment.Left,
		Size = UDim2.new(1, -60, 0, 22),
		ZIndex = 21,
		Parent = root,
	}, 20)
	timerLabel = UIKit.label({
		TextXAlignment = Enum.TextXAlignment.Right,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(1, 0),
		Size = UDim2.fromOffset(56, 22),
		ZIndex = 21,
		Parent = root,
	}, 20)
	whoLabel = UIKit.label({
		TextColor3 = UIKit.Colors.TextDim,
		TextXAlignment = Enum.TextXAlignment.Left,
		Position = UDim2.fromOffset(0, 26),
		Size = UDim2.new(1, 0, 0, 18),
		ZIndex = 21,
		Parent = root,
	}, 15)
	answerLabel = UIKit.label({
		Font = UIKit.Fonts.Header,
		TextColor3 = UIKit.Colors.Text,
		Position = UDim2.fromOffset(0, 46),
		Size = UDim2.new(1, 0, 0, 52),
		ZIndex = 21,
		Parent = root,
	}, 40, 12)

	validButton = UIKit.button({
		Text = "VALID",
		BackgroundColor3 = UIKit.Colors.PhosphorDim,
		TextColor3 = UIKit.Colors.Text,
		Position = UDim2.fromOffset(0, 112),
		Size = UDim2.new(0.5, -5, 0, 60),
		ZIndex = 21,
		Parent = root,
	}, UIKit.Colors.Phosphor, 26)
	validButton.TextColor3 = Color3.fromRGB(235, 245, 232)
	wrongButton = UIKit.button({
		Text = "GIBBERISH / WRONG",
		BackgroundColor3 = UIKit.Colors.RedDim,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, 0, 0, 112),
		Size = UDim2.new(0.5, -5, 0, 60),
		ZIndex = 21,
		Parent = root,
	}, UIKit.Colors.Red, 22)
	wrongButton.TextColor3 = Color3.fromRGB(250, 228, 224)
	validButton.Activated:Connect(function()
		judge("Valid")
	end)
	wrongButton.Activated:Connect(function()
		judge("Wrong")
	end)
end

function JudgePanel.update()
	local snapshot = State.snapshot
	local judging = snapshot and snapshot.judging
	if not visible or not snapshot or not judging then
		return
	end
	if turnId ~= judging.turnId then
		turnId = judging.turnId
		lastSeconds = -1
		local locked = judgedTurnId == turnId
		UIKit.setEnabled(validButton, not locked)
		UIKit.setEnabled(wrongButton, not locked)
		UIKit.setText(headerLabel, if locked then "VERDICT SENT" else "JUDGE THE ANSWER")
	end
	local category = if snapshot.category then string.upper(snapshot.category) else "?"
	UIKit.setText(whoLabel, `{string.upper(State.nameOf(judging.userId))} SAID  ·  {category}`)
	UIKit.setText(answerLabel, `"{judging.answer}"`)
end

function JudgePanel.setVisible(on: boolean)
	if on == visible then
		if on then
			JudgePanel.update()
		end
		return
	end
	visible = on
	if on then
		turnId = nil
		JudgePanel.update()
		UIKit.reveal(root, 12)
	else
		root.Visible = false
	end
end

function JudgePanel.step()
	local snapshot = State.snapshot
	local judging = snapshot and snapshot.judging
	if not visible or not judging then
		return
	end
	local seconds = math.max(0, math.ceil(judging.deadline - State.now()))
	if seconds ~= lastSeconds then
		lastSeconds = seconds
		timerLabel.Text = UIKit.clock(seconds)
		timerLabel.TextColor3 = if seconds <= 3 then UIKit.Colors.Red else UIKit.Colors.Text
	end
end

return JudgePanel
