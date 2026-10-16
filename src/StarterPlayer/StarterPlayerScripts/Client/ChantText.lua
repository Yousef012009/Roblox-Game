--!strict
--[[
	ChantText  (ModuleScript)  ·  StarterPlayerScripts/Client/ChantText

	COUNTDOWN cinematic text driven by MusicTimeline.chantFrame(beat): the
	current chant line with the active syllable lit and the rest dim. During
	the sting it shows Config.ChantStingText, then reveals the category big.
	Rebuilds its string only when the whole beat changes.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local MusicTimeline = require(ReplicatedStorage.Shared.MusicTimeline)
local State = require(script.Parent.State)
local UIKit = require(script.Parent.UIKit)

local ChantText = {}

local POP = TweenInfo.new(0.22, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
-- Half-way through the sting the category itself appears.
local REVEAL_BEAT = MusicTimeline.StingStartBeat + 2

local root: Frame
local lineLabel: TextLabel
local categoryLabel: TextLabel
local lineScale: UIScale
local visible = false
local lastWhole: number? = nil
local lastCategory: string? = nil

local DIM = "#56605a"
local LIT = "#9ee0a2"

local function escape(text: string): string
	local escaped = string.gsub(text, "&", "&amp;")
	escaped = string.gsub(escaped, "<", "&lt;")
	escaped = string.gsub(escaped, ">", "&gt;")
	return escaped
end

function ChantText.mount(parent: Instance)
	root = UIKit.new("Frame", {
		Name = "ChantText",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.new(0.94, 0, 0, 150),
		Visible = false,
		ZIndex = 15,
		Parent = parent,
	}, { UIKit.sizeLimit(Vector2.new(0, 0), Vector2.new(980, 150)) })
	lineLabel = UIKit.label({
		Font = UIKit.Fonts.Header,
		RichText = true,
		TextStrokeTransparency = 0.4,
		Size = UDim2.new(1, 0, 0, 64),
		ZIndex = 16,
		Parent = root,
	}, 64, 16)
	lineScale = UIKit.new("UIScale", { Scale = 1, Parent = lineLabel })
	categoryLabel = UIKit.label({
		Font = UIKit.Fonts.Header,
		TextColor3 = UIKit.Colors.Phosphor,
		TextStrokeTransparency = 0.3,
		Position = UDim2.fromOffset(0, 70),
		Size = UDim2.new(1, 0, 0, 72),
		Visible = false,
		ZIndex = 16,
		Parent = root,
	}, 72, 16)
end

function ChantText.setVisible(on: boolean)
	if on == visible then
		return
	end
	visible = on
	root.Visible = on
	lastWhole = nil
	lastCategory = nil
end

local function renderChant(frame: MusicTimeline.ChantFrame)
	local syllables: { string } = frame.syllables or {}
	local parts = table.create(#syllables)
	for i, syllable in syllables do
		local color = if i == frame.active then LIT else DIM
		parts[i] = `<font color="{color}">{escape(syllable)}</font>`
	end
	lineLabel.Text = table.concat(parts, " ")
	categoryLabel.Visible = false
end

local function renderSting(whole: number)
	lineLabel.Text = `<font color="#cdd4cb">{escape(Config.ChantStingText)}</font>`
	local category = State.snapshot and State.snapshot.category
	local reveal = whole >= REVEAL_BEAT and category ~= nil
	if reveal and category then
		if lastCategory ~= category then
			lastCategory = category
			categoryLabel.Text = string.upper(category)
		end
		if not categoryLabel.Visible then
			categoryLabel.Visible = true
			UIKit.reveal(categoryLabel, 14)
		end
	else
		categoryLabel.Visible = false
	end
end

function ChantText.step(beat: number?)
	if not visible then
		return
	end
	if beat == nil then
		-- Silent fallback without a song clock: just show the category.
		local category = State.snapshot and State.snapshot.category
		UIKit.setText(lineLabel, "")
		if category and lastCategory ~= category then
			lastCategory = category
			categoryLabel.Text = string.upper(category)
			categoryLabel.Visible = true
		end
		return
	end
	local whole = math.floor(beat)
	if whole == lastWhole then
		return
	end
	lastWhole = whole
	local frame = MusicTimeline.chantFrame(beat)
	if frame.kind == "Chant" then
		renderChant(frame)
	elseif frame.kind == "Sting" then
		renderSting(whole)
	else
		lineLabel.Text = if beat < 0 then `<font color="{DIM}">. . .</font>` else ""
		if beat >= MusicTimeline.LoopStartBeat then
			renderSting(whole) -- keep the category up until PLAYING takes over
		end
		return
	end
	lineScale.Scale = 1.12
	UIKit.tween(lineScale, POP, { Scale = 1 })
end

return ChantText
