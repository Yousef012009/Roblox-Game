--!strict
--[[
	IntroOverlay  (ModuleScript)  ·  StarterPlayerScripts/Client/IntroOverlay

	INTRO cinematic: letterbox bars slide in and "INTERROGATION ROOM n" is
	typed out character by character, with a dim case-file subtitle.
]]

local UIKit = require(script.Parent.UIKit)

local IntroOverlay = {}

local BAR_SCALE = 0.13
local CHARS_PER_SECOND = 22
local BAR_TWEEN = TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

local root: Frame
local topBar: Frame
local bottomBar: Frame
local title: TextLabel
local subtitle: TextLabel
local fullTitle = ""
local shownChars = -1
local startedAt = 0
local visible = false

function IntroOverlay.mount(parent: Instance)
	root = UIKit.new("Frame", {
		Name = "IntroOverlay",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Visible = false,
		ZIndex = 30,
		Parent = parent,
	})
	local function bar(anchorY: number): Frame
		return UIKit.new("Frame", {
			BackgroundColor3 = UIKit.Colors.Black,
			BorderSizePixel = 0,
			AnchorPoint = Vector2.new(0, anchorY),
			Position = UDim2.fromScale(0, anchorY),
			Size = UDim2.fromScale(1, 0),
			ZIndex = 30,
			Parent = root,
		})
	end
	topBar = bar(0)
	bottomBar = bar(1)
	title = UIKit.label({
		Font = UIKit.Fonts.Header,
		TextColor3 = UIKit.Colors.Text,
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.fromScale(0.5, 0.82),
		Size = UDim2.new(0.9, 0, 0, 44),
		ZIndex = 31,
		Parent = root,
	}, 40, 14)
	subtitle = UIKit.label({
		TextColor3 = UIKit.Colors.TextDim,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.fromScale(0.5, 0.82),
		Size = UDim2.new(0.9, 0, 0, 20),
		ZIndex = 31,
		Parent = root,
	}, 15)
end

-- roomNumber is 1-based; caseId is a short id shown as flavour.
function IntroOverlay.show(roomNumber: number, caseId: string)
	fullTitle = `INTERROGATION ROOM {roomNumber}`
	UIKit.setText(subtitle, `CASE FILE {caseId}  ·  NO REPEATS. NO HESITATION.`)
	if visible then
		return
	end
	visible = true
	startedAt = os.clock()
	shownChars = -1
	title.Text = ""
	topBar.Size = UDim2.fromScale(1, 0)
	bottomBar.Size = UDim2.fromScale(1, 0)
	root.Visible = true
	UIKit.tween(topBar, BAR_TWEEN, { Size = UDim2.fromScale(1, BAR_SCALE) })
	UIKit.tween(bottomBar, BAR_TWEEN, { Size = UDim2.fromScale(1, BAR_SCALE) })
end

function IntroOverlay.hide()
	if not visible then
		return
	end
	visible = false
	root.Visible = false
end

-- Typewriter: only touches the label when another character appears.
function IntroOverlay.step()
	if not visible then
		return
	end
	local count = math.min(#fullTitle, math.floor((os.clock() - startedAt - 0.3) * CHARS_PER_SECOND))
	if count ~= shownChars and count >= 0 then
		shownChars = count
		local cursor = if count < #fullTitle then "_" else ""
		title.Text = string.sub(fullTitle, 1, count) .. cursor
	end
end

return IntroOverlay
