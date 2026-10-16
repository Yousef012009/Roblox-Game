--!strict
--[[
	UIKit  (ModuleScript)  ·  StarterPlayerScripts/Client/UIKit

	The game's design system: a "film-noir case file" look that is
	high-contrast and readable on a phone.

	  • Ink-dark panels, off-white "paper" text, evidence-tape AMBER accent
	  • Typewriter titles (Special Elite), chunky cartoony display text
	    (Fredoka One), clean UI body text (Builder Sans)
	  • Big touch targets (≥ 44 px) and scale-based sizes with min/max
	    constraints, so layouts hold up from a small phone to a 4K monitor

	`UIKit.create` keeps the UI code declarative:

	    UIKit.create("TextLabel", { Text = "Hi", Parent = frame }, { UIKit.corner(8) })
]]

local TweenService = game:GetService("TweenService")

local UIKit = {}

UIKit.Colors = table.freeze({
	Ink = Color3.fromRGB(14, 17, 23), -- panel background
	InkSoft = Color3.fromRGB(30, 35, 46), -- raised elements
	Line = Color3.fromRGB(58, 64, 78), -- hairlines / idle strokes
	Paper = Color3.fromRGB(244, 237, 222), -- primary text
	Muted = Color3.fromRGB(150, 156, 170), -- secondary text
	Amber = Color3.fromRGB(255, 196, 61), -- primary accent (evidence tape)
	Red = Color3.fromRGB(235, 72, 72), -- danger / elimination / low time
	Green = Color3.fromRGB(88, 214, 141), -- success
	Blue = Color3.fromRGB(96, 165, 250), -- info / skip
	Robux = Color3.fromRGB(0, 176, 111), -- buy buttons
})

UIKit.Fonts = table.freeze({
	Title = Enum.Font.SpecialElite, -- typewriter
	Display = Enum.Font.FredokaOne, -- big cartoony callouts
	Body = Enum.Font.BuilderSansBold,
	Heavy = Enum.Font.BuilderSansExtraBold,
})

-- Instance factory. Sets `Parent` last for performance.
function UIKit.create(className: string, props: { [string]: any }?, children: { any }?): any
	local instance = Instance.new(className :: any)
	local properties: { [string]: any } = props or {}
	local childList: { Instance } = children or {}
	local parent = nil
	for key, value in properties do
		if key == "Parent" then
			parent = value
		else
			(instance :: any)[key] = value
		end
	end
	for _, child in childList do
		child.Parent = instance
	end
	if parent then
		instance.Parent = parent
	end
	return instance
end

----------------------------------------------------------------------------
-- Modifiers (typed as Instance so they mix freely in `children` lists)
----------------------------------------------------------------------------
function UIKit.corner(radius: number?): Instance
	return UIKit.create("UICorner", { CornerRadius = UDim.new(0, radius or 12) })
end

function UIKit.round(): Instance
	return UIKit.create("UICorner", { CornerRadius = UDim.new(1, 0) })
end

function UIKit.stroke(color: Color3?, thickness: number?, transparency: number?): Instance
	return UIKit.create("UIStroke", {
		Color = color or UIKit.Colors.Line,
		Thickness = thickness or 2,
		Transparency = transparency or 0,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
	})
end

function UIKit.padding(x: number, y: number?): Instance
	return UIKit.create("UIPadding", {
		PaddingLeft = UDim.new(0, x),
		PaddingRight = UDim.new(0, x),
		PaddingTop = UDim.new(0, y or x),
		PaddingBottom = UDim.new(0, y or x),
	})
end

function UIKit.textSize(maxSize: number, minSize: number?): Instance
	return UIKit.create("UITextSizeConstraint", { MaxTextSize = maxSize, MinTextSize = minSize or 10 })
end

function UIKit.sizeLimit(minSize: Vector2, maxSize: Vector2): Instance
	return UIKit.create("UISizeConstraint", { MinSize = minSize, MaxSize = maxSize })
end

function UIKit.list(direction: Enum.FillDirection, gap: number, hAlign: Enum.HorizontalAlignment?, vAlign: Enum.VerticalAlignment?): Instance
	return UIKit.create("UIListLayout", {
		FillDirection = direction,
		Padding = UDim.new(0, gap),
		HorizontalAlignment = hAlign or Enum.HorizontalAlignment.Center,
		VerticalAlignment = vAlign or Enum.VerticalAlignment.Center,
		SortOrder = Enum.SortOrder.LayoutOrder,
	})
end

----------------------------------------------------------------------------
-- Components
----------------------------------------------------------------------------
-- Transparent, auto-scaling text label.
function UIKit.label(props: { [string]: any }, maxTextSize: number?): TextLabel
	local defaults: { [string]: any } = {
		BackgroundTransparency = 1,
		TextScaled = true,
		Font = UIKit.Fonts.Body,
		TextColor3 = UIKit.Colors.Paper,
		Text = "",
	}
	for key, value in props do
		defaults[key] = value
	end
	return UIKit.create("TextLabel", defaults, { UIKit.textSize(maxTextSize or 28) })
end

-- Dark rounded panel.
function UIKit.panel(props: { [string]: any }, radius: number?): Frame
	local defaults: { [string]: any } = {
		BackgroundColor3 = UIKit.Colors.Ink,
		BackgroundTransparency = 0.08,
		BorderSizePixel = 0,
	}
	for key, value in props do
		defaults[key] = value
	end
	return UIKit.create("Frame", defaults, { UIKit.corner(radius or 14), UIKit.stroke(UIKit.Colors.Line, 1.5, 0.2) })
end

-- Chunky, touch-friendly button with a press "squish".
function UIKit.button(props: { [string]: any }, color: Color3?, textColor: Color3?): TextButton
	local defaults: { [string]: any } = {
		AutoButtonColor = false,
		BackgroundColor3 = color or UIKit.Colors.Amber,
		BorderSizePixel = 0,
		Font = UIKit.Fonts.Heavy,
		TextColor3 = textColor or UIKit.Colors.Ink,
		TextScaled = true,
		Text = "",
	}
	for key, value in props do
		defaults[key] = value
	end
	local scale = UIKit.create("UIScale", { Scale = 1 })
	local button: TextButton = UIKit.create("TextButton", defaults, {
		UIKit.corner(12),
		UIKit.textSize(22, 10),
		UIKit.padding(10, 6),
		scale,
	})
	button.MouseButton1Down:Connect(function()
		UIKit.tween(scale, 0.06, { Scale = 0.94 })
	end)
	local function release()
		UIKit.tween(scale, 0.12, { Scale = 1 }, Enum.EasingStyle.Back)
	end
	button.MouseButton1Up:Connect(release)
	button.MouseLeave:Connect(release)
	return button
end

----------------------------------------------------------------------------
-- Motion
----------------------------------------------------------------------------
function UIKit.tween(instance: Instance, duration: number, goal: { [string]: any }, style: Enum.EasingStyle?, direction: Enum.EasingDirection?): Tween
	local tween = TweenService:Create(
		instance,
		TweenInfo.new(duration, style or Enum.EasingStyle.Quad, direction or Enum.EasingDirection.Out),
		goal
	)
	tween:Play()
	return tween
end

-- Quick "punch" on a UIScale (beats, new turn, results).
function UIKit.pop(scale: UIScale, amount: number?)
	scale.Scale = amount or 1.12
	UIKit.tween(scale, 0.25, { Scale = 1 }, Enum.EasingStyle.Back)
end

-- Hex string for RichText <font color="">.
function UIKit.hex(color: Color3): string
	return "#" .. color:ToHex()
end

return UIKit
