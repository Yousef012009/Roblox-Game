--!strict
--[[
	ScreenFader  (ModuleScript)  ·  StarterPlayerScripts/Client/ScreenFader

	Full-screen fade to / from black (elevator departure, the eliminated
	victim's move to the lounge) plus one caption line drawn over the black
	(the elevator floor indicator). Lives in its own ScreenGui with
	IgnoreGuiInset so the black really covers the whole screen, top bar area
	included. It never blocks input (Active = false) and can never get stuck:
	every fadeOut carries a maximum hold after which it fades back in.
]]

local Players = game:GetService("Players")

local TextFX = require(script.Parent.TextFX)
local UIKit = require(script.Parent.UIKit)

local ScreenFader = {}

local DEFAULT_MAX_HOLD = 8

local gui: ScreenGui? = nil
local black: Frame
local caption: TextLabel
local serial = 0 -- invalidates pending auto fade-ins
local current: Tween? = nil
local dark = false

function ScreenFader.mount()
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
	local existing = playerGui:FindFirstChild("Concentration64Fader")
	if existing then
		existing:Destroy()
	end
	gui = UIKit.new("ScreenGui", {
		Name = "Concentration64Fader",
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		ScreenInsets = Enum.ScreenInsets.None,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		DisplayOrder = 30, -- above the game UI (10)
		Parent = playerGui,
	})
	black = UIKit.new("Frame", {
		Name = "Black",
		BackgroundColor3 = UIKit.Colors.Black,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		Visible = false,
		Active = false,
		ZIndex = 1,
		Parent = gui,
	})
	caption = UIKit.label({
		Name = "Caption",
		Font = UIKit.Fonts.Display,
		TextColor3 = UIKit.Colors.Amber,
		TextTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.new(0.9, 0, 0, 40),
		ZIndex = 2,
		Parent = black,
	}, 30, 12)
end

local function play(goal: number, seconds: number)
	if current then
		current:Cancel()
		current = nil
	end
	black.Visible = true
	if seconds <= 0 then
		black.BackgroundTransparency = goal
	else
		current = UIKit.tween(
			black,
			TweenInfo.new(seconds, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut),
			{ BackgroundTransparency = goal }
		)
	end
end

-- Fades to black; fades back in by itself after `maxHold` seconds.
function ScreenFader.fadeOut(seconds: number, maxHold: number?)
	if not gui then
		return
	end
	serial += 1
	local mySerial = serial
	dark = true
	play(0, seconds)
	task.delay(seconds + (maxHold or DEFAULT_MAX_HOLD), function()
		if serial == mySerial and dark then
			ScreenFader.fadeIn(0.6)
		end
	end)
end

function ScreenFader.fadeIn(seconds: number)
	if not gui then
		return
	end
	serial += 1
	local mySerial = serial
	if not dark and not black.Visible then
		return
	end
	dark = false
	play(1, seconds)
	UIKit.tween(caption, TweenInfo.new(math.max(seconds, 0.05)), { TextTransparency = 1 })
	task.delay(seconds + 0.05, function()
		if serial == mySerial and not dark then
			black.Visible = false
			TextFX.cancel(caption, "")
		end
	end)
end

-- Snaps back to fully clear (lobby return / reset).
function ScreenFader.clear()
	if not gui then
		return
	end
	serial += 1
	dark = false
	if current then
		current:Cancel()
		current = nil
	end
	black.BackgroundTransparency = 1
	black.Visible = false
	TextFX.cancel(caption, "")
	caption.TextTransparency = 1
end

-- Caption over the black (typed). Empty string hides it.
function ScreenFader.setCaption(text: string, color: Color3?)
	if not gui then
		return
	end
	caption.TextColor3 = color or UIKit.Colors.Amber
	if text == "" then
		TextFX.cancel(caption, "")
		caption.TextTransparency = 1
		return
	end
	black.Visible = true
	caption.TextTransparency = 0
	TextFX.typeIfChanged(caption, text, { cps = 40 })
end

function ScreenFader.isDark(): boolean
	return dark
end

return ScreenFader
