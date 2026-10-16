--!strict
--[[
	Toasts  (ModuleScript)  ·  StarterPlayerScripts/Client/Toasts

	Small stacked notices under the HUD (Notify, Notice, JudgeTimeout,
	InputRejected...). A fixed pool of slots is built once and recycled.
]]

local UIKit = require(script.Parent.UIKit)

export type Kind = "Info" | "Error" | "Warn" | "Good"

local Toasts = {}

local SLOT_COUNT = 3
local LIFETIME = 3.4
local SLOT_HEIGHT = 30
local TOP_OFFSET = 122 -- below the game HUD + metronome

type Slot = { frame: Frame, label: TextLabel, bar: Frame, expiresAt: number, serial: number }

local slots: { Slot } = {}
local serial = 0

local KIND_COLORS: { [Kind]: Color3 } = {
	Info = UIKit.Colors.Text,
	Error = UIKit.Colors.Red,
	Warn = UIKit.Colors.Amber,
	Good = UIKit.Colors.Phosphor,
}

function Toasts.mount(parent: Instance)
	local holder = UIKit.new("Frame", {
		Name = "Toasts",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, TOP_OFFSET),
		Size = UDim2.new(0.92, 0, 0, SLOT_COUNT * (SLOT_HEIGHT + 4)),
		ZIndex = 40,
		Parent = parent,
	}, {
		UIKit.sizeLimit(Vector2.new(0, 0), Vector2.new(460, math.huge)),
		UIKit.new("UIListLayout", {
			FillDirection = Enum.FillDirection.Vertical,
			HorizontalAlignment = Enum.HorizontalAlignment.Center,
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, 4),
		}),
	})
	for i = 1, SLOT_COUNT do
		local frame = UIKit.panel({
			Name = `Toast{i}`,
			Size = UDim2.new(1, 0, 0, SLOT_HEIGHT),
			Visible = false,
			ZIndex = 40,
			Parent = holder,
		})
		local bar = UIKit.new("Frame", {
			BorderSizePixel = 0,
			BackgroundColor3 = UIKit.Colors.Text,
			Size = UDim2.new(0, 3, 1, 0),
			ZIndex = 41,
			Parent = frame,
		})
		local label = UIKit.label({
			Position = UDim2.fromOffset(10, 0),
			Size = UDim2.new(1, -16, 1, 0),
			TextXAlignment = Enum.TextXAlignment.Left,
			ZIndex = 41,
			Parent = frame,
		}, 16, 9)
		table.insert(slots, { frame = frame, label = label, bar = bar, expiresAt = 0, serial = 0 })
	end
end

-- Shows a toast; the oldest one is reused when all slots are busy.
function Toasts.show(text: string, kind: Kind?)
	if #slots == 0 or text == "" then
		return
	end
	serial += 1
	local chosen = slots[1]
	for _, slot in slots do
		if not slot.frame.Visible then
			chosen = slot
			break
		end
		if slot.serial < chosen.serial then
			chosen = slot
		end
	end
	local resolved: Kind = kind or "Info"
	local color = KIND_COLORS[resolved]
	chosen.serial = serial
	chosen.expiresAt = os.clock() + LIFETIME
	chosen.frame.LayoutOrder = serial
	chosen.label.Text = string.upper(text)
	chosen.label.TextColor3 = color
	chosen.bar.BackgroundColor3 = color
	chosen.frame.Visible = false
	UIKit.reveal(chosen.frame, -6)
end

function Toasts.step()
	local now = os.clock()
	for _, slot in slots do
		if slot.frame.Visible and now >= slot.expiresAt then
			slot.frame.Visible = false
		end
	end
end

return Toasts
