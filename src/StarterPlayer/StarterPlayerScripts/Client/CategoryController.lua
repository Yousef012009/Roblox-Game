--!strict
--[[
	CategoryController  (ModuleScript)  ·  StarterPlayerScripts/Client/CategoryController

	The Caller's picker:

	  ┌──────────────────────────────────────┐
	  │ YOU'RE THE CALLER                 12 │
	  │ "I'll go first, to my left,          │
	  │  the category is…"                   │
	  │ [ Fruits       ] [ Board Games     ] │  ← random presets (2 columns)
	  │ [ Superheroes  ] [ Things That Fly ] │
	  │ …                                    │
	  │ [ type anything…            ][ GO ]  │  ← Custom Category pass owners
	  │   or  [ 🔓 CUSTOM CATEGORIES · R$99 ] │  ← upsell for everyone else
	  └──────────────────────────────────────┘
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared:WaitForChild("Remotes"))
local WordRules = require(Shared:WaitForChild("WordRules"))
local UIKit = require(script.Parent.UIKit)

local C = UIKit.Colors
local F = UIKit.Fonts

local CategoryController = {}
CategoryController.__index = CategoryController

export type CategoryController = typeof(setmetatable(
	{} :: {
		_overlay: Frame,
		_timer: TextLabel,
		_grid: ScrollingFrame,
		_customRow: Frame,
		_customBox: TextBox,
		_customGo: TextButton,
		_unlock: TextButton,
		_hint: TextLabel,
		_prompt: Remotes.CategoryPrompt?,
		_locked: boolean,
		_passLabel: () -> string,
	},
	CategoryController
))

function CategoryController.new(screen: ScreenGui, passLabel: () -> string): CategoryController
	local self = setmetatable({}, CategoryController) :: any
	self._locked = false
	self._passLabel = passLabel

	self._overlay = UIKit.create("Frame", {
		Name = "CategoryPicker",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Color3.new(0, 0, 0),
		BackgroundTransparency = 0.45,
		Visible = false,
		ZIndex = 10,
		Parent = screen,
	})

	local card = UIKit.panel({
		Name = "Card",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(0.92, 0.86),
		Parent = self._overlay,
	}, 18)
	UIKit.sizeLimit(Vector2.new(280, 260), Vector2.new(540, 470)).Parent = card
	UIKit.padding(16, 14).Parent = card

	UIKit.label({
		Name = "Title",
		Size = UDim2.new(1, -60, 0, 32),
		Font = F.Title,
		TextColor3 = C.Amber,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = "YOU'RE THE CALLER",
		Parent = card,
	}, 30)
	self._timer = UIKit.label({
		Name = "Timer",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(1, 0),
		Size = UDim2.fromOffset(56, 32),
		Font = F.Display,
		TextXAlignment = Enum.TextXAlignment.Right,
		Parent = card,
	}, 30)
	UIKit.label({
		Name = "Line",
		Position = UDim2.fromOffset(0, 34),
		Size = UDim2.new(1, 0, 0, 22),
		TextColor3 = C.Muted,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = "“I'll go first, to my left, the category is…”",
		Parent = card,
	}, 18)

	self._grid = UIKit.create("ScrollingFrame", {
		Name = "Options",
		Position = UDim2.fromOffset(0, 64),
		Size = UDim2.new(1, 0, 1, -124),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 4,
		ScrollBarImageColor3 = C.Muted,
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		Parent = card,
	}, {
		UIKit.create("UIGridLayout", {
			CellSize = UDim2.new(0.5, -5, 0, 46), -- two columns of big touch targets
			CellPadding = UDim2.fromOffset(8, 8),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
	})

	-- Bottom row: custom entry (pass owners)...
	self._customRow = UIKit.create("Frame", {
		Name = "Custom",
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.fromScale(0, 1),
		Size = UDim2.new(1, 0, 0, 48),
		BackgroundColor3 = C.InkSoft,
		Visible = false,
		Parent = card,
	}, { UIKit.corner(12), UIKit.stroke(C.Amber, 1.5) })
	self._customBox = UIKit.create("TextBox", {
		Name = "Input",
		Position = UDim2.fromOffset(12, 6),
		Size = UDim2.new(1, -100, 1, -12),
		BackgroundTransparency = 1,
		ClearTextOnFocus = false,
		Font = F.Body,
		PlaceholderText = "Type any category…",
		PlaceholderColor3 = C.Muted,
		Text = "",
		TextColor3 = C.Paper,
		TextScaled = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = self._customRow,
	}, { UIKit.textSize(22, 12) })
	self._customGo = UIKit.button({
		Name = "Go",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -5, 0.5, 0),
		Size = UDim2.new(0, 76, 1, -10),
		Text = "GO",
		Parent = self._customRow,
	})

	-- ...or the upsell.
	self._unlock = UIKit.button({
		Name = "Unlock",
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.fromScale(0, 1),
		Size = UDim2.new(1, 0, 0, 46),
		Text = "🔓 CUSTOM CATEGORIES",
		Visible = false,
		Parent = card,
	}, C.Robux, C.Paper)

	self._hint = UIKit.label({
		Name = "Hint",
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 0, 1, -52),
		Size = UDim2.new(1, 0, 0, 18),
		TextColor3 = C.Red,
		Parent = card,
	}, 16)

	local function sendCustom()
		if self._locked or not self._prompt then
			return
		end
		local ok, cleanedOrReason = WordRules.validateCategory(self._customBox.Text)
		if not ok then
			self._hint.Text = cleanedOrReason
			return
		end
		self._locked = true
		self._customGo.Text = "…"
		Remotes.SubmitCategory:FireServer("Custom", cleanedOrReason)
		-- If the server rejects it (filtered), unlock again after a moment.
		task.delay(2.5, function()
			if self._prompt then
				self._locked = false
				self._customGo.Text = "GO"
			end
		end)
	end
	self._customGo.Activated:Connect(sendCustom)
	self._customBox.FocusLost:Connect(function(enterPressed: boolean)
		if enterPressed then
			sendCustom()
		end
	end)
	self._unlock.Activated:Connect(function()
		Remotes.RequestPurchase:FireServer("CustomCategory")
	end)
	return self
end

function CategoryController.show(self: CategoryController, prompt: Remotes.CategoryPrompt)
	local wasOpen = self._prompt ~= nil
	self._prompt = prompt
	self._locked = false
	self._hint.Text = ""
	self._customGo.Text = "GO"
	if not wasOpen then
		self._customBox.Text = ""
	end

	for _, child in self._grid:GetChildren() do
		if child:IsA("TextButton") then
			child:Destroy()
		end
	end
	for order, option in prompt.options do
		local button = UIKit.button({
			Name = option.name,
			Text = option.name,
			LayoutOrder = order,
			Parent = self._grid,
		}, C.InkSoft, C.Paper)
		UIKit.stroke(C.Line, 1.5).Parent = button
		button.Activated:Connect(function()
			if self._locked then
				return
			end
			self._locked = true
			button.BackgroundColor3 = C.Amber
			button.TextColor3 = C.Ink
			Remotes.SubmitCategory:FireServer("Preset", option.index)
		end)
	end

	self._customRow.Visible = prompt.canCustom
	self._unlock.Visible = not prompt.canCustom and prompt.customEnabled
	self._unlock.Text = `🔓 TYPE YOUR OWN CATEGORY · {self._passLabel()}`
	local hasBottomRow = self._customRow.Visible or self._unlock.Visible
	self._grid.Size = UDim2.new(1, 0, 1, if hasBottomRow then -142 else -70)
	self._overlay.Visible = true
end

function CategoryController.hide(self: CategoryController)
	self._prompt = nil
	self._overlay.Visible = false
	self._customBox:ReleaseFocus()
end

function CategoryController.isOpen(self: CategoryController): boolean
	return self._prompt ~= nil
end

function CategoryController.update(self: CategoryController, serverNow: number)
	local prompt = self._prompt
	if prompt then
		local remaining = math.max(0, prompt.endsAt - serverNow)
		self._timer.Text = tostring(math.ceil(remaining))
		self._timer.TextColor3 = if remaining <= 3 then C.Red else C.Paper
	end
end

return CategoryController
