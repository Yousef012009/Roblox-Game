--!strict
--[[
	UIKit  (ModuleScript)  ·  StarterPlayerScripts/Client/UIKit

	Tiny programmatic UI toolkit + the visual theme ("PS1 detective OS"):
	dark translucent panels, desaturated greys, phosphor green accents, red
	for elimination, 1 px borders, monospace body text.

	Every screen builds its instances ONCE through these helpers and later
	only changes text / visibility (UIKit.setText skips identical writes).

	Motion (cheap, tween-only, no per-frame work):
	  • reveal()   panels slide in with a slight Back overshoot + scale pop
	  • button()   squish on press, brighten on hover (wired once at build)
	  • pulse()    a quick scale "pop" (timers, metronome, stamps)
	One UIScale per object is shared by all of these; an object may carry a
	"BaseScale" attribute (e.g. a viewport-fit scale) that motion returns to.
]]

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")

local UIKit = {}

UIKit.Colors = {
	Panel = Color3.fromRGB(14, 16, 15),
	PanelLight = Color3.fromRGB(26, 29, 27),
	Border = Color3.fromRGB(70, 78, 72),
	Text = Color3.fromRGB(206, 212, 204),
	TextDim = Color3.fromRGB(120, 128, 120),
	TextFaint = Color3.fromRGB(70, 76, 70),
	Phosphor = Color3.fromRGB(122, 196, 128),
	PhosphorDim = Color3.fromRGB(56, 96, 60),
	Red = Color3.fromRGB(196, 52, 44),
	RedDim = Color3.fromRGB(92, 26, 22),
	Amber = Color3.fromRGB(210, 168, 92),
	Black = Color3.fromRGB(0, 0, 0),
}

UIKit.Fonts = {
	Body = Enum.Font.Code,
	BodyAlt = Enum.Font.RobotoMono,
	Header = Enum.Font.SpecialElite,
	Display = Enum.Font.Arcade,
}

UIKit.PanelTransparency = 0.18
UIKit.TouchMin = 44 -- minimum touch target (px)

-- Shared vertical layout of the match screens (px from the top safe inset).
-- The HUD reserves two chip rows so up to 8 participants fit on a phone.
UIKit.Layout = {
	HudTop = 4,
	HudHeight = 100,
	MetronomeTop = 108, -- under the HUD
	BelowHud = 136, -- under the HUD + metronome: toasts, cards, focused inputs
}

local QUICK = TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local OVERSHOOT = TweenInfo.new(0.32, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local PRESS = TweenInfo.new(0.07, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local RELEASE = TweenInfo.new(0.22, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local HOVER = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local PRESS_SCALE = 0.92
local HOVER_LIFT = 0.16 -- background lerp toward the accent while hovered

export type Props = { [string]: any }

-- Generic constructor: new("Frame", { Size = ..., Parent = ... }, { children }).
-- Parent is assigned last so the instance is fully configured before it
-- enters the DataModel.
function UIKit.new(className: string, props: Props?, children: { any }?): any
	local inst: any = Instance.new(className :: any)
	local parent: Instance? = nil
	if props then
		for key, value in props do
			if key == "Parent" then
				parent = value
			else
				inst[key] = value
			end
		end
	end
	if children then
		for _, child in children do
			child.Parent = inst
		end
	end
	if parent then
		inst.Parent = parent
	end
	return inst
end

function UIKit.stroke(color: Color3?, thickness: number?, transparency: number?): any
	return UIKit.new("UIStroke", {
		Color = color or UIKit.Colors.Border,
		Thickness = thickness or 1,
		Transparency = transparency or 0.2,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
	})
end

function UIKit.corner(px: number?): any
	return UIKit.new("UICorner", { CornerRadius = UDim.new(0, px or 2) })
end

function UIKit.padding(px: number): any
	local p = UDim.new(0, px)
	return UIKit.new("UIPadding", { PaddingLeft = p, PaddingRight = p, PaddingTop = p, PaddingBottom = p })
end

function UIKit.sizeLimit(minSize: Vector2, maxSize: Vector2): UISizeConstraint
	return UIKit.new("UISizeConstraint", { MinSize = minSize, MaxSize = maxSize })
end

-- Dark translucent bordered panel.
function UIKit.panel(props: Props): Frame
	local merged: Props = {
		BackgroundColor3 = UIKit.Colors.Panel,
		BackgroundTransparency = UIKit.PanelTransparency,
		BorderSizePixel = 0,
	}
	for k, v in props do
		merged[k] = v
	end
	return UIKit.new("Frame", merged, { UIKit.stroke(), UIKit.corner(2) })
end

-- TextLabel that scales its text to fit, clamped by maxTextSize (so long
-- strings shrink instead of overflowing on small phones).
function UIKit.label(props: Props, maxTextSize: number?, minTextSize: number?): TextLabel
	local merged: Props = {
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Font = UIKit.Fonts.Body,
		TextColor3 = UIKit.Colors.Text,
		TextScaled = true,
		TextWrapped = true,
		Text = "",
	}
	for k, v in props do
		merged[k] = v
	end
	return UIKit.new("TextLabel", merged, {
		UIKit.new("UITextSizeConstraint", { MaxTextSize = maxTextSize or 20, MinTextSize = minTextSize or 8 }),
	})
end

-- Flat bordered button. `accent` colours the border and text.
function UIKit.button(props: Props, accent: Color3?, maxTextSize: number?): TextButton
	local color = accent or UIKit.Colors.Text
	local merged: Props = {
		BackgroundColor3 = UIKit.Colors.PanelLight,
		BackgroundTransparency = 0.1,
		BorderSizePixel = 0,
		AutoButtonColor = false, -- bindButtonMotion does hover / press feedback
		Font = UIKit.Fonts.Body,
		TextColor3 = color,
		TextScaled = true,
		Text = "",
	}
	for k, v in props do
		merged[k] = v
	end
	local button: TextButton = UIKit.new("TextButton", merged, {
		UIKit.stroke(color, 1, 0.1),
		UIKit.corner(2),
		UIKit.padding(4),
		UIKit.new("UITextSizeConstraint", { MaxTextSize = maxTextSize or 20, MinTextSize = 10 }),
	})
	UIKit.bindButtonMotion(button, color)
	return button
end

-- The UIScale every motion helper shares (created on first use).
function UIKit.scaleOf(gui: GuiObject): UIScale
	local existing = gui:FindFirstChildOfClass("UIScale")
	if existing then
		return existing
	end
	local created: UIScale = UIKit.new("UIScale", { Name = "MotionScale", Scale = UIKit.baseScale(gui), Parent = gui })
	return created
end

function UIKit.baseScale(gui: GuiObject): number
	local base = gui:GetAttribute("BaseScale")
	return if type(base) == "number" then base else 1
end

-- Squish on press, brighten on hover. Wired once per button for the life of
-- the (never-reset) ScreenGui; disabled buttons (Active = false) stay still.
function UIKit.bindButtonMotion(button: GuiButton, accent: Color3)
	local hoverColor: Color3? = nil
	local baseColor = button.BackgroundColor3
	local function release()
		local scale = UIKit.scaleOf(button)
		UIKit.tween(scale, RELEASE, { Scale = UIKit.baseScale(button) })
	end
	local function unhover()
		if hoverColor and button.BackgroundColor3 == hoverColor then
			UIKit.tween(button, HOVER, { BackgroundColor3 = baseColor })
		end
		hoverColor = nil
	end
	button.MouseButton1Down:Connect(function()
		if button.Active then
			UIKit.tween(UIKit.scaleOf(button), PRESS, { Scale = UIKit.baseScale(button) * PRESS_SCALE })
		end
	end)
	button.MouseButton1Up:Connect(release)
	button.MouseEnter:Connect(function()
		if not button.Active then
			return
		end
		baseColor = button.BackgroundColor3
		local lifted = baseColor:Lerp(accent, HOVER_LIFT)
		hoverColor = lifted
		UIKit.tween(button, HOVER, { BackgroundColor3 = lifted })
	end)
	button.MouseLeave:Connect(function()
		release()
		unhover()
	end)
end

-- A quick scale pop (peak -> base) on any GuiObject.
function UIKit.pulse(gui: GuiObject, peak: number?, seconds: number?)
	local scale = UIKit.scaleOf(gui)
	local base = UIKit.baseScale(gui)
	scale.Scale = base * (peak or 1.25)
	UIKit.tween(
		scale,
		TweenInfo.new(seconds or 0.28, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
		{ Scale = base }
	)
end

-- Rich-text escaping for user-provided strings.
function UIKit.escape(text: string): string
	local escaped = string.gsub(text, "&", "&amp;")
	escaped = string.gsub(escaped, "<", "&lt;")
	escaped = string.gsub(escaped, ">", "&gt;")
	return escaped
end

-- Enables/disables a button and dims it.
function UIKit.setEnabled(button: GuiButton, enabled: boolean)
	if button.Active == enabled then
		return
	end
	button.Active = enabled
	local textButton = button :: any
	if button:IsA("TextButton") then
		textButton.TextTransparency = if enabled then 0 else 0.6
	end
	local stroke = button:FindFirstChildOfClass("UIStroke")
	if stroke then
		stroke.Transparency = if enabled then 0.1 else 0.7
	end
end

-- Writes text only when it changed (avoids needless layout passes).
function UIKit.setText(label: GuiObject, text: string)
	local textual = label :: any
	if textual.Text ~= text then
		textual.Text = text
	end
end

function UIKit.setVisible(gui: GuiObject, visible: boolean)
	if gui.Visible ~= visible then
		gui.Visible = visible
	end
end

function UIKit.tween(inst: Instance, info: TweenInfo?, goal: { [string]: any }): Tween
	local tween = TweenService:Create(inst, info or QUICK, goal)
	tween:Play()
	return tween
end

-- Shows a frame with a short slide-in from `fromOffsetY` px below its resting
-- position (resting position stored as an attribute on first use), with a
-- slight overshoot and a scale pop. `fromOffsetX` slides sideways instead.
function UIKit.reveal(frame: GuiObject, fromOffsetY: number?, fromOffsetX: number?)
	local rest = frame:GetAttribute("RestPosition")
	if typeof(rest) ~= "UDim2" then
		rest = frame.Position
		frame:SetAttribute("RestPosition", rest)
	end
	local restPos = rest :: UDim2
	if frame.Visible then
		return
	end
	frame.Position = restPos + UDim2.fromOffset(fromOffsetX or 0, fromOffsetY or 8)
	frame.Visible = true
	UIKit.tween(frame, OVERSHOOT, { Position = restPos })
	local scale = UIKit.scaleOf(frame)
	local base = UIKit.baseScale(frame)
	scale.Scale = base * 0.94
	UIKit.tween(scale, OVERSHOOT, { Scale = base })
end

-- Moves a revealed frame's resting position (e.g. on orientation change).
function UIKit.setRestPosition(frame: GuiObject, position: UDim2)
	frame:SetAttribute("RestPosition", position)
	frame.Position = position
end

-- "m:ss" for a number of seconds (rounded up, never negative).
function UIKit.clock(seconds: number): string
	local s = math.max(0, math.ceil(seconds))
	return string.format("%d:%02d", s // 60, s % 60)
end

-- The one ScreenGui every client screen lives in.
function UIKit.screenGui(name: string, displayOrder: number): ScreenGui
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
	local existing = playerGui:FindFirstChild(name)
	if existing then
		existing:Destroy()
	end
	return UIKit.new("ScreenGui", {
		Name = name,
		ResetOnSpawn = false,
		IgnoreGuiInset = false,
		ScreenInsets = Enum.ScreenInsets.CoreUISafeInsets,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		DisplayOrder = displayOrder,
		Parent = playerGui,
	})
end

-- Restrained CRT dressing: a handful of faint horizontal bands plus a cheap
-- vignette made of four gradient edges. Static (no per-frame cost).
function UIKit.crtOverlay(parent: Instance)
	local root = UIKit.new("Frame", {
		Name = "CRT",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 50,
		Active = false,
		Parent = parent,
	})
	for i = 0, 5 do
		UIKit.new("Frame", {
			BackgroundColor3 = UIKit.Colors.Black,
			BackgroundTransparency = 0.93,
			BorderSizePixel = 0,
			Position = UDim2.fromScale(0, i / 6),
			Size = UDim2.new(1, 0, 0, 2),
			ZIndex = 50,
			Parent = root,
		})
	end
	local edges = {
		{ pos = UDim2.fromScale(0, 0), size = UDim2.fromScale(1, 0.12), rot = 90 },
		{ pos = UDim2.fromScale(0, 0.88), size = UDim2.fromScale(1, 0.12), rot = 270 },
		{ pos = UDim2.fromScale(0, 0), size = UDim2.fromScale(0.08, 1), rot = 0 },
		{ pos = UDim2.fromScale(0.92, 0), size = UDim2.fromScale(0.08, 1), rot = 180 },
	}
	for _, edge in edges do
		UIKit.new("Frame", {
			BackgroundColor3 = UIKit.Colors.Black,
			BackgroundTransparency = 0,
			BorderSizePixel = 0,
			Position = edge.pos,
			Size = edge.size,
			ZIndex = 50,
			Parent = root,
		}, {
			UIKit.new("UIGradient", {
				Rotation = edge.rot,
				Transparency = NumberSequence.new(0.55, 1),
			}),
		})
	end
end

return UIKit
