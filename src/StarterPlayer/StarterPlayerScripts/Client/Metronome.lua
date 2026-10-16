--!strict
--[[
	Metronome  (ModuleScript)  ·  StarterPlayerScripts/Client/Metronome

	Compact "1 • 2 • 3 • 4" beat indicator under the HUD. The current beat of
	the measure (MusicTimeline.measureOf on the local, calibrated beat) is lit
	and pulses; work happens only when the whole beat changes.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MusicTimeline = require(ReplicatedStorage.Shared.MusicTimeline)
local UIKit = require(script.Parent.UIKit)

local Metronome = {}

local PULSE = TweenInfo.new(0.28, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

local root: Frame
local digits: { TextLabel } = {}
local scales: { UIScale } = {}
local visible = false
local lastWhole: number? = nil

function Metronome.mount(parent: Instance)
	root = UIKit.new("Frame", {
		Name = "Metronome",
		BackgroundColor3 = UIKit.Colors.Panel,
		BackgroundTransparency = 0.35,
		BorderSizePixel = 0,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 94),
		Size = UDim2.fromOffset(176, 24),
		Visible = false,
		ZIndex = 5,
		Parent = parent,
	}, {
		UIKit.stroke(UIKit.Colors.Border, 1, 0.5),
		UIKit.corner(2),
		UIKit.new("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal,
			HorizontalAlignment = Enum.HorizontalAlignment.Center,
			VerticalAlignment = Enum.VerticalAlignment.Center,
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
	})
	local order = 0
	for i = 1, MusicTimeline.BeatsPerMeasure do
		if i > 1 then
			order += 1
			UIKit.label({
				Text = "•",
				TextColor3 = UIKit.Colors.TextFaint,
				LayoutOrder = order,
				Size = UDim2.fromOffset(18, 20),
				ZIndex = 6,
				Parent = root,
			}, 14)
		end
		order += 1
		local digit = UIKit.label({
			Text = tostring(i),
			Font = UIKit.Fonts.Display,
			TextColor3 = UIKit.Colors.TextFaint,
			LayoutOrder = order,
			Size = UDim2.fromOffset(22, 20),
			ZIndex = 6,
			Parent = root,
		}, 18)
		local scale = UIKit.new("UIScale", { Scale = 1, Parent = digit })
		table.insert(digits, digit)
		table.insert(scales, scale)
	end
end

function Metronome.setVisible(on: boolean)
	if on == visible then
		return
	end
	visible = on
	root.Visible = on
	lastWhole = nil
end

function Metronome.step(beat: number?)
	if not visible then
		return
	end
	if beat == nil or beat < 0 then
		if lastWhole ~= nil then
			lastWhole = nil
			for _, digit in digits do
				digit.TextColor3 = UIKit.Colors.TextFaint
			end
		end
		return
	end
	local whole = math.floor(beat)
	if whole == lastWhole then
		return
	end
	lastWhole = whole
	local _, inMeasure = MusicTimeline.measureOf(beat)
	local current = inMeasure + 1
	for i, digit in digits do
		if i == current then
			digit.TextColor3 = if i == 1 then UIKit.Colors.Amber else UIKit.Colors.Phosphor
			scales[i].Scale = 1.45
			UIKit.tween(scales[i], PULSE, { Scale = 1 })
		else
			digit.TextColor3 = UIKit.Colors.TextFaint
		end
	end
end

return Metronome
