--!strict
--[[
	IntroOverlay  (ModuleScript)  ·  StarterPlayerScripts/Client/IntroOverlay

	INTRO cinematic: letterbox bars slide in, old-film grain flickers over the
	picture (a few specks and scratches re-rolled ~12 times a second plus a
	brightness flicker; no textures), "INTERROGATION ROOM n" is typed out
	character by character and then the case-file line types itself:
	"CASE FILE #A1B2C3 · NO REPEATS. NO HESITATION."
]]

local TextFX = require(script.Parent.TextFX)
local UIKit = require(script.Parent.UIKit)

local IntroOverlay = {}

local BAR_SCALE = 0.13
local CHARS_PER_SECOND = 22
local BAR_TWEEN = TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local GRAIN_FPS = 12
local SPECKS = 10
local SCRATCHES = 3

local root: Frame
local topBar: Frame
local bottomBar: Frame
local title: TextLabel
local subtitle: TextLabel
local grain: Frame
local flicker: Frame
local grainBits: { Frame } = {}
local grainAccumulator = 0
local grainClock = 0
local random = Random.new()
local fullTitle = ""
local fullSubtitle = ""
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
	grain = UIKit.new("Frame", {
		Name = "FilmGrain",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Active = false,
		ZIndex = 29,
		Parent = root,
	})
	flicker = UIKit.new("Frame", {
		Name = "Flicker",
		BackgroundColor3 = UIKit.Colors.Black,
		BackgroundTransparency = 0.94,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 29,
		Parent = grain,
	})
	for i = 1, SPECKS + SCRATCHES do
		local scratch = i > SPECKS
		table.insert(
			grainBits,
			UIKit.new("Frame", {
				BackgroundColor3 = if scratch then Color3.fromRGB(220, 214, 196) else UIKit.Colors.Black,
				BackgroundTransparency = if scratch then 0.65 else 0.35,
				BorderSizePixel = 0,
				Size = if scratch then UDim2.new(0, 1, 0.6, 0) else UDim2.fromOffset(3, 3),
				ZIndex = 29,
				Parent = grain,
			})
		)
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
	fullSubtitle = `CASE FILE #{caseId}  ·  NO REPEATS. NO HESITATION.`
	if visible then
		return
	end
	-- The case-file line types itself once the title is done.
	TextFX.type(subtitle, fullSubtitle, { cps = 34, delay = 0.45 + #fullTitle / CHARS_PER_SECOND, cursor = true })
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
	TextFX.cancel(subtitle, "")
end

-- Re-rolls the specks / scratches and the brightness flicker.
local function stepGrain(dt: number)
	grainAccumulator += dt
	grainClock += dt
	if grainAccumulator < 1 / GRAIN_FPS then
		return
	end
	grainAccumulator = 0
	for i, bit in grainBits do
		local scratch = i > SPECKS
		bit.Visible = random:NextNumber() < (if scratch then 0.35 else 0.7)
		if bit.Visible then
			bit.Position = UDim2.fromScale(random:NextNumber(), if scratch then random:NextNumber(0, 0.4) else random:NextNumber())
		end
	end
	-- Projector flicker: mostly steady, with an occasional dip.
	local dip = if random:NextNumber() < 0.12 then 0.12 else 0
	flicker.BackgroundTransparency = 0.95 - dip - 0.02 * math.sin(grainClock * 31)
end

-- Typewriter: only touches the label when another character appears.
function IntroOverlay.step(dt: number)
	if not visible then
		return
	end
	stepGrain(dt)
	local count = math.min(#fullTitle, math.floor((os.clock() - startedAt - 0.3) * CHARS_PER_SECOND))
	if count ~= shownChars and count >= 0 then
		shownChars = count
		local cursor = if count < #fullTitle then "_" else ""
		title.Text = string.sub(fullTitle, 1, count) .. cursor
	end
end

return IntroOverlay
