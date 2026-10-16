--!strict
--[[
	EliminationOverlay  (ModuleScript)  ·  StarterPlayerScripts/Client/EliminationOverlay

	Victim: red flash + red vignette + a glitching "ELIMINATED" (typed with
	scrambled glyphs, jittering for a moment) + reason. Everyone else: a
	lighter red flash and a smaller banner. Both disappear after ~2 s so the
	spectator view is never blocked for long. Non-blocking (Active = false):
	taps pass through.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Remotes = require(ReplicatedStorage.Shared.Remotes)
local TextFX = require(script.Parent.TextFX)
local UIKit = require(script.Parent.UIKit)

local EliminationOverlay = {}

local VICTIM_SECONDS = 2.1
local BANNER_SECONDS = 2.0
local FLASH = TweenInfo.new(0.7, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local GLITCH_SECONDS = 0.7
local JITTER_PX = 5

local REASON_TEXT: { [Remotes.EliminationReason]: string } = {
	Hesitation = "HESITATION",
	Repeat = "REPEAT",
	Rejected = "GIBBERISH",
	Left = "LEFT",
}

local flash: Frame
local vignette: CanvasGroup
local victimRoot: Frame
local victimTitle: TextLabel
local titleRest = UDim2.new()
local victimReason: TextLabel
local banner: Frame
local bannerLabel: TextLabel
local hideAt = 0
local glitchUntil = 0
local random = Random.new()

function EliminationOverlay.mount(parent: Instance)
	flash = UIKit.new("Frame", {
		Name = "EliminationFlash",
		BackgroundColor3 = UIKit.Colors.Red,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		Visible = false,
		Active = false,
		ZIndex = 35,
		Parent = parent,
	})
	vignette = UIKit.new("CanvasGroup", {
		Name = "RedVignette",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		GroupTransparency = 1,
		Visible = false,
		Active = false,
		ZIndex = 34,
		Parent = parent,
	})
	local edges = {
		{ pos = UDim2.fromScale(0, 0), size = UDim2.fromScale(1, 0.3), rot = 90 },
		{ pos = UDim2.fromScale(0, 0.7), size = UDim2.fromScale(1, 0.3), rot = 270 },
		{ pos = UDim2.fromScale(0, 0), size = UDim2.fromScale(0.25, 1), rot = 0 },
		{ pos = UDim2.fromScale(0.75, 0), size = UDim2.fromScale(0.25, 1), rot = 180 },
	}
	for _, edge in edges do
		UIKit.new("Frame", {
			BackgroundColor3 = UIKit.Colors.Red,
			BorderSizePixel = 0,
			Position = edge.pos,
			Size = edge.size,
			ZIndex = 34,
			Parent = vignette,
		}, {
			UIKit.new("UIGradient", { Rotation = edge.rot, Transparency = NumberSequence.new(0.15, 1) }),
		})
	end
	victimRoot = UIKit.new("Frame", {
		Name = "Eliminated",
		BackgroundColor3 = UIKit.Colors.Black,
		BackgroundTransparency = 0.35,
		BorderSizePixel = 0,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.42),
		Size = UDim2.new(1, 0, 0, 120),
		Visible = false,
		Active = false,
		ZIndex = 36,
		Parent = parent,
	})
	titleRest = UDim2.new(0.5, 0, 0, 10)
	victimTitle = UIKit.label({
		Text = "ELIMINATED",
		Font = UIKit.Fonts.Header,
		TextColor3 = UIKit.Colors.Red,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = titleRest,
		Size = UDim2.new(0.9, 0, 0, 64),
		ZIndex = 37,
		Parent = victimRoot,
	}, 64, 20)
	victimReason = UIKit.label({
		TextColor3 = UIKit.Colors.Text,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 78),
		Size = UDim2.new(0.9, 0, 0, 30),
		ZIndex = 37,
		Parent = victimRoot,
	}, 22)

	banner = UIKit.panel({
		Name = "EliminationBanner",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, UIKit.Layout.BelowHud + 4),
		Size = UDim2.new(0.86, 0, 0, 40),
		Visible = false,
		Active = false,
		ZIndex = 36,
		Parent = parent,
	})
	UIKit.sizeLimit(Vector2.new(0, 0), Vector2.new(480, 40)).Parent = banner
	local stroke = banner:FindFirstChildOfClass("UIStroke")
	if stroke then
		stroke.Color = UIKit.Colors.Red
	end
	bannerLabel = UIKit.label({
		TextColor3 = UIKit.Colors.Red,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 37,
		Parent = banner,
	}, 18)
end

local function reasonLine(reason: Remotes.EliminationReason?, answer: string?): string
	local text = if reason then REASON_TEXT[reason] or "OUT" else "OUT"
	if reason == "Repeat" and answer then
		return `{text}: "{answer}" WAS ALREADY SAID`
	elseif reason == "Rejected" and answer then
		return `{text}: "{answer}"`
	end
	return text
end

function EliminationOverlay.showVictim(reason: Remotes.EliminationReason?, answer: string?)
	banner.Visible = false
	victimReason.Text = reasonLine(reason, answer)
	flash.BackgroundTransparency = 0.35
	flash.Visible = true
	UIKit.tween(flash, FLASH, { BackgroundTransparency = 1 })
	vignette.GroupTransparency = 0
	vignette.Visible = true
	UIKit.tween(
		vignette,
		TweenInfo.new(VICTIM_SECONDS, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
		{ GroupTransparency = 1 }
	)
	victimRoot.Visible = true
	TextFX.type(victimTitle, "ELIMINATED", { cps = 30, glitch = true, glitchSeconds = 0.35 })
	UIKit.pulse(victimTitle, 1.35, 0.4)
	glitchUntil = os.clock() + GLITCH_SECONDS
	hideAt = os.clock() + VICTIM_SECONDS
end

function EliminationOverlay.showOther(name: string, reason: Remotes.EliminationReason?, answer: string?)
	if victimRoot.Visible then
		return -- the local player's own overlay wins
	end
	bannerLabel.Text = `{string.upper(name)} ELIMINATED  ·  {reasonLine(reason, answer)}`
	TextFX.type(bannerLabel, bannerLabel.Text, { cps = 60, glitch = true })
	flash.BackgroundTransparency = 0.8
	flash.Visible = true
	UIKit.tween(flash, FLASH, { BackgroundTransparency = 1 })
	banner.Visible = false
	UIKit.reveal(banner, -8)
	hideAt = os.clock() + BANNER_SECONDS
end

function EliminationOverlay.hide()
	flash.Visible = false
	vignette.Visible = false
	victimRoot.Visible = false
	banner.Visible = false
	glitchUntil = 0
	victimTitle.Position = titleRest
	victimTitle.TextColor3 = UIKit.Colors.Red
end

function EliminationOverlay.step()
	local now = os.clock()
	if (victimRoot.Visible or banner.Visible or flash.Visible or vignette.Visible) and now >= hideAt then
		EliminationOverlay.hide()
		return
	end
	if glitchUntil > 0 then
		if now < glitchUntil then
			-- Jitter + colour tearing while the title glitches in.
			victimTitle.Position = titleRest
				+ UDim2.fromOffset(random:NextInteger(-JITTER_PX, JITTER_PX), random:NextInteger(-2, 2))
			victimTitle.TextColor3 = if random:NextNumber() < 0.25 then UIKit.Colors.Text else UIKit.Colors.Red
		else
			glitchUntil = 0
			victimTitle.Position = titleRest
			victimTitle.TextColor3 = UIKit.Colors.Red
		end
	end
end

return EliminationOverlay
