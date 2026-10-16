--!strict
--[[
	EliminationOverlay  (ModuleScript)  ·  StarterPlayerScripts/Client/EliminationOverlay

	Victim: brief red flash + "ELIMINATED" + reason. Everyone else: a smaller
	banner. Both disappear after ~2 s so the spectator view is never blocked
	for long. Non-blocking (Active = false): taps pass through.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Remotes = require(ReplicatedStorage.Shared.Remotes)
local UIKit = require(script.Parent.UIKit)

local EliminationOverlay = {}

local VICTIM_SECONDS = 2.1
local BANNER_SECONDS = 2.0
local FLASH = TweenInfo.new(0.7, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

local REASON_TEXT: { [Remotes.EliminationReason]: string } = {
	Hesitation = "HESITATION",
	Repeat = "REPEAT",
	Rejected = "GIBBERISH",
	Left = "LEFT",
}

local flash: Frame
local victimRoot: Frame
local victimReason: TextLabel
local banner: Frame
local bannerLabel: TextLabel
local hideAt = 0

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
	UIKit.label({
		Text = "ELIMINATED",
		Font = UIKit.Fonts.Header,
		TextColor3 = UIKit.Colors.Red,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 10),
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
		Position = UDim2.new(0.5, 0, 0, 126),
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
	victimRoot.Visible = true
	hideAt = os.clock() + VICTIM_SECONDS
end

function EliminationOverlay.showOther(name: string, reason: Remotes.EliminationReason?, answer: string?)
	if victimRoot.Visible then
		return -- the local player's own overlay wins
	end
	bannerLabel.Text = `{string.upper(name)} ELIMINATED  ·  {reasonLine(reason, answer)}`
	flash.BackgroundTransparency = 0.8
	flash.Visible = true
	UIKit.tween(flash, FLASH, { BackgroundTransparency = 1 })
	banner.Visible = false
	UIKit.reveal(banner, -8)
	hideAt = os.clock() + BANNER_SECONDS
end

function EliminationOverlay.hide()
	flash.Visible = false
	victimRoot.Visible = false
	banner.Visible = false
end

function EliminationOverlay.step()
	if (victimRoot.Visible or banner.Visible or flash.Visible) and os.clock() >= hideAt then
		EliminationOverlay.hide()
	end
end

return EliminationOverlay
