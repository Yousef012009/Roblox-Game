--!strict
--[[
	InfoCard  (ModuleScript)  ·  StarterPlayerScripts/Client/InfoCard

	A centred status card used for "waiting" moments:
	  CALLER_SELECTION     "YOU ARE THE CALLER" / "<NAME> IS THE CALLER"
	  CATEGORY_SELECTION   "<NAME> IS CHOOSING A CATEGORY..."  + countdown
	  JUDGING (non-Caller) "CALLER IS JUDGING" + the answer
	Optional countdown to a server-clock deadline.
]]

local State = require(script.Parent.State)
local TextFX = require(script.Parent.TextFX)
local UIKit = require(script.Parent.UIKit)

local InfoCard = {}

local root: Frame
local accentBar: Frame
local titleLabel: TextLabel
local bodyLabel: TextLabel
local timerLabel: TextLabel
local deadline: number? = nil
local lastSeconds = -1
local visible = false

function InfoCard.mount(parent: Instance)
	root = UIKit.panel({
		Name = "InfoCard",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, UIKit.Layout.BelowHud + 4),
		Size = UDim2.new(0.9, 0, 0, 96),
		Visible = false,
		ZIndex = 10,
		Parent = parent,
	})
	UIKit.sizeLimit(Vector2.new(0, 0), Vector2.new(520, 96)).Parent = root
	accentBar = UIKit.new("Frame", {
		BorderSizePixel = 0,
		BackgroundColor3 = UIKit.Colors.Phosphor,
		Size = UDim2.new(1, 0, 0, 2),
		ZIndex = 11,
		Parent = root,
	})
	titleLabel = UIKit.label({
		Font = UIKit.Fonts.Header,
		Position = UDim2.fromOffset(12, 8),
		Size = UDim2.new(1, -24, 0, 34),
		ZIndex = 11,
		Parent = root,
	}, 28, 12)
	bodyLabel = UIKit.label({
		TextColor3 = UIKit.Colors.TextDim,
		Position = UDim2.fromOffset(12, 44),
		Size = UDim2.new(1, -24, 0, 24),
		ZIndex = 11,
		Parent = root,
	}, 17)
	timerLabel = UIKit.label({
		TextColor3 = UIKit.Colors.Phosphor,
		Position = UDim2.fromOffset(12, 70),
		Size = UDim2.new(1, -24, 0, 18),
		ZIndex = 11,
		Parent = root,
	}, 15)
end

function InfoCard.show(title: string, body: string?, endsAt: number?, accent: Color3?)
	if titleLabel.Text ~= title then
		titleLabel.Text = title
		if visible then
			UIKit.pulse(titleLabel, 1.1, 0.3)
		end
	end
	TextFX.typeIfChanged(bodyLabel, body or "", { cps = 55 })
	accentBar.BackgroundColor3 = accent or UIKit.Colors.Phosphor
	titleLabel.TextColor3 = accent or UIKit.Colors.Text
	if deadline ~= endsAt then
		deadline = endsAt
		lastSeconds = -1
	end
	UIKit.setVisible(timerLabel, endsAt ~= nil)
	if not visible then
		visible = true
		UIKit.reveal(root, 10)
	end
	InfoCard.step()
end

function InfoCard.hide()
	visible = false
	UIKit.setVisible(root, false)
end

function InfoCard.step()
	local endsAt = deadline
	if not visible or not endsAt then
		return
	end
	local seconds = math.max(0, math.ceil(endsAt - State.now()))
	if seconds ~= lastSeconds then
		lastSeconds = seconds
		timerLabel.Text = UIKit.clock(seconds)
		timerLabel.TextColor3 = if seconds <= 2 then UIKit.Colors.Red else UIKit.Colors.Phosphor
		if seconds <= 2 and seconds > 0 then
			UIKit.pulse(timerLabel, 1.3, 0.35)
		end
	end
end

return InfoCard
