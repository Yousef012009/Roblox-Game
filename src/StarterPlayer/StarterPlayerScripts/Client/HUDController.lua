--!strict
--[[
	HUDController  (ModuleScript)  ·  StarterPlayerScripts/Client/HUDController

	The always-on heads-up display:

	  ┌──────────────────────────────────────────────┐
	  │ (metronome)  CASE FILE · FRUITS          7   │  ← header: category, turn, timer
	  │              YOUR TURN!                       │
	  │ ▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬            │  ← draining timer bar
	  └──────────────────────────────────────────────┘
	   [ Ann ] [ Bob ] [ ~~Cat~~ ] [ Dee ]             ← roster chips (turn order)
	   toasts…

	              CON · CEN · TRA · TION!             ← centre banner (chant / results)

	Everything is anchored top-centre so the bottom of the screen stays free
	for the answer box and the phone keyboard.
]]

local Remotes = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Remotes"))
local UIKit = require(script.Parent.UIKit)

local C = UIKit.Colors
local F = UIKit.Fonts

local HUDController = {}
HUDController.__index = HUDController

export type HUD = typeof(setmetatable(
	{} :: {
		metronomeHolder: Frame,
		_turnLabel: TextLabel,
		_turnScale: UIScale,
		_categoryLabel: TextLabel,
		_timerLabel: TextLabel,
		_timerBar: Frame,
		_timerFill: Frame,
		_roster: Frame,
		_toasts: Frame,
		_spectatorTag: Frame,
		_banner: Frame,
		_bannerLabel: TextLabel,
		_bannerSub: TextLabel,
		_bannerScale: UIScale,
		_bannerToken: number,
		_toastCount: number,
	},
	HUDController
))

function HUDController.new(screen: ScreenGui): HUD
	local self = setmetatable({}, HUDController) :: any

	------------------------------------------------------------------ top stack
	local top = UIKit.create("Frame", {
		Name = "Top",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 6),
		Size = UDim2.new(0.94, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		Parent = screen,
	}, {
		UIKit.list(Enum.FillDirection.Vertical, 6, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Top),
		UIKit.sizeLimit(Vector2.new(0, 0), Vector2.new(580, math.huge)),
	})

	local header = UIKit.panel({ Name = "Header", Size = UDim2.new(1, 0, 0, 66), LayoutOrder = 1, Parent = top })

	self.metronomeHolder = UIKit.create("Frame", {
		Name = "Metronome",
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 7, 0.5, -2),
		Size = UDim2.fromOffset(50, 50),
		BackgroundColor3 = C.InkSoft,
		Parent = header,
	}, { UIKit.corner(10) })

	local textBlock = UIKit.create("Frame", {
		Name = "Text",
		Position = UDim2.new(0, 66, 0, 5),
		Size = UDim2.new(1, -140, 1, -16),
		BackgroundTransparency = 1,
		Parent = header,
	})
	self._categoryLabel = UIKit.label({
		Name = "Category",
		Size = UDim2.fromScale(1, 0.42),
		Font = F.Title,
		TextColor3 = C.Amber,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = "CASE FILE · —",
		Parent = textBlock,
	}, 18)
	self._turnScale = UIKit.create("UIScale")
	self._turnLabel = UIKit.label({
		Name = "Turn",
		Position = UDim2.fromScale(0, 0.42),
		Size = UDim2.fromScale(1, 0.58),
		Font = F.Display,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = "WAITING FOR SUSPECTS",
		Parent = textBlock,
	}, 26)
	self._turnScale.Parent = self._turnLabel

	self._timerLabel = UIKit.label({
		Name = "Timer",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -10, 0.5, -3),
		Size = UDim2.fromOffset(60, 44),
		Font = F.Display,
		TextXAlignment = Enum.TextXAlignment.Right,
		Parent = header,
	}, 40)

	self._timerBar = UIKit.create("Frame", {
		Name = "TimerBar",
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 10, 1, -5),
		Size = UDim2.new(1, -20, 0, 4),
		BackgroundColor3 = C.InkSoft,
		BorderSizePixel = 0,
		Visible = false,
		Parent = header,
	}, { UIKit.round() })
	self._timerFill = UIKit.create("Frame", {
		Name = "Fill",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = C.Amber,
		BorderSizePixel = 0,
		Parent = self._timerBar,
	}, { UIKit.round() })

	self._roster = UIKit.create("Frame", {
		Name = "Roster",
		Size = UDim2.new(1, 0, 0, 26),
		BackgroundTransparency = 1,
		LayoutOrder = 2,
		Parent = top,
	}, { UIKit.list(Enum.FillDirection.Horizontal, 6) })

	self._spectatorTag = UIKit.panel({
		Name = "SpectatorTag",
		Size = UDim2.new(0.8, 0, 0, 26),
		LayoutOrder = 3,
		Visible = false,
		Parent = top,
	}, 13)
	UIKit.label({
		Size = UDim2.fromScale(1, 1),
		Text = "👁  SPECTATOR LOUNGE · behind the two-way mirror",
		TextColor3 = C.Muted,
		Parent = self._spectatorTag,
	}, 15)

	self._toasts = UIKit.create("Frame", {
		Name = "Toasts",
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		LayoutOrder = 4,
		Parent = top,
	}, { UIKit.list(Enum.FillDirection.Vertical, 4, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Top) })

	------------------------------------------------------------------ centre banner
	self._banner = UIKit.create("Frame", {
		Name = "Banner",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.42),
		Size = UDim2.new(0.92, 0, 0, 120),
		BackgroundTransparency = 1,
		Visible = false,
		Parent = screen,
	}, { UIKit.sizeLimit(Vector2.new(0, 0), Vector2.new(900, 120)) })
	self._bannerScale = UIKit.create("UIScale", { Parent = self._banner })
	self._bannerLabel = UIKit.label({
		Name = "Main",
		Size = UDim2.fromScale(1, 0.7),
		Font = F.Display,
		RichText = true,
		Parent = self._banner,
	}, 64)
	UIKit.create("UIStroke", { Color = C.Ink, Thickness = 3, Parent = self._bannerLabel })
	self._bannerSub = UIKit.label({
		Name = "Sub",
		Position = UDim2.fromScale(0, 0.7),
		Size = UDim2.fromScale(1, 0.3),
		Font = F.Body,
		Parent = self._banner,
	}, 24)
	UIKit.create("UIStroke", { Color = C.Ink, Thickness = 2, Parent = self._bannerSub })

	self._bannerToken = 0
	self._toastCount = 0
	return self
end

----------------------------------------------------------------------------
-- Header
----------------------------------------------------------------------------
function HUDController.setCategory(self: HUD, category: string?)
	self._categoryLabel.Text = if category then `CASE FILE · {string.upper(category)}` else "CASE FILE · —"
end

function HUDController.setTurn(self: HUD, text: string, color: Color3?, pulse: boolean?)
	self._turnLabel.Text = text
	self._turnLabel.TextColor3 = color or C.Paper
	if pulse then
		UIKit.pop(self._turnScale, 1.15)
	end
end

-- seconds = nil hides the timer. `fraction` drives the bar (1 → full).
function HUDController.setTimer(self: HUD, seconds: number?, fraction: number?, urgent: boolean?)
	if seconds == nil then
		self._timerLabel.Text = ""
		self._timerBar.Visible = false
		return
	end
	local color = if urgent then C.Red else C.Paper
	self._timerLabel.Text = tostring(math.max(0, math.ceil(seconds)))
	self._timerLabel.TextColor3 = color
	if fraction then
		self._timerBar.Visible = true
		self._timerFill.Size = UDim2.fromScale(math.clamp(fraction, 0, 1), 1)
		self._timerFill.BackgroundColor3 = if urgent then C.Red else C.Amber
	else
		self._timerBar.Visible = false
	end
end

----------------------------------------------------------------------------
-- Roster chips
----------------------------------------------------------------------------
function HUDController.setRoster(self: HUD, roster: { Remotes.RosterEntry }, currentUserId: number?, myUserId: number)
	for _, child in self._roster:GetChildren() do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end

	local sorted = table.clone(roster)
	table.sort(sorted, function(a, b)
		return a.seat < b.seat
	end)

	for _, entry in sorted do
		local isCurrent = entry.userId == currentUserId
		local out = entry.status == "Eliminated" or entry.status == "Left"
		local background = if isCurrent then C.Amber elseif out then C.Ink else C.InkSoft
		local textColor = if isCurrent then C.Ink elseif out then C.Red elseif entry.status == "Pending" then C.Amber else C.Paper

		local chip = UIKit.create("Frame", {
			Name = `Seat{entry.seat}`,
			Size = UDim2.new(1 / math.max(#sorted, 1), -6, 1, 0),
			BackgroundColor3 = background,
			BackgroundTransparency = if out then 0.35 else 0,
			LayoutOrder = entry.seat,
			Parent = self._roster,
		}, { UIKit.corner(8) })
		if entry.userId == myUserId then
			UIKit.stroke(C.Amber, 1.5).Parent = chip
		end

		local name = if entry.status == "Pending" then `💰 {entry.name}` else entry.name
		UIKit.label({
			Size = UDim2.fromScale(1, 1),
			RichText = true,
			Text = if out then `<s>{name}</s>` else name,
			TextColor3 = textColor,
			TextTruncate = Enum.TextTruncate.AtEnd,
			Parent = chip,
		}, 15)
		UIKit.padding(6, 3).Parent = chip
	end
end

function HUDController.setSpectating(self: HUD, spectating: boolean)
	self._spectatorTag.Visible = spectating
end

----------------------------------------------------------------------------
-- Toasts
----------------------------------------------------------------------------
local TOAST_COLORS: { [string]: Color3 } = {
	Info = C.Paper,
	Success = C.Green,
	Error = C.Red,
}

function HUDController.toast(self: HUD, message: string, kind: string?)
	self._toastCount += 1
	local toast = UIKit.panel({
		Name = "Toast",
		Size = UDim2.new(0.9, 0, 0, 28),
		LayoutOrder = self._toastCount,
		Parent = self._toasts,
	}, 14)
	UIKit.label({
		Size = UDim2.fromScale(1, 1),
		Text = message,
		TextColor3 = TOAST_COLORS[kind or "Info"] or C.Paper,
		Parent = toast,
	}, 16)
	UIKit.padding(10, 4).Parent = toast

	-- Keep at most three on screen.
	local toasts = {}
	for _, child in self._toasts:GetChildren() do
		if child:IsA("Frame") then
			table.insert(toasts, child)
		end
	end
	table.sort(toasts, function(a, b)
		return a.LayoutOrder < b.LayoutOrder
	end)
	for i = 1, #toasts - 3 do
		toasts[i]:Destroy()
	end

	task.delay(3.2, function()
		if toast.Parent then
			toast:Destroy()
		end
	end)
end

----------------------------------------------------------------------------
-- Centre banner
----------------------------------------------------------------------------
-- Flash a message (results, announcements). `hold` = seconds before it hides.
function HUDController.showBanner(self: HUD, text: string, color: Color3?, sub: string?, hold: number?)
	self._bannerToken += 1
	local token = self._bannerToken
	self._banner.Visible = true
	self._bannerLabel.Text = text
	self._bannerLabel.TextColor3 = color or C.Paper
	self._bannerSub.Text = sub or ""
	UIKit.pop(self._bannerScale, 1.2)

	local duration = hold or 1.6
	if duration ~= math.huge then
		task.delay(duration, function()
			if self._bannerToken == token then
				self._banner.Visible = false
			end
		end)
	end
end

-- Persistent banner for the chant (RichText). Pass nil to clear.
function HUDController.setChant(self: HUD, richText: string?, sub: string?, pop: boolean?)
	if richText == nil then
		self._bannerToken += 1
		self._banner.Visible = false
		return
	end
	self._bannerToken += 1
	self._banner.Visible = true
	self._bannerLabel.Text = richText
	self._bannerLabel.TextColor3 = C.Paper
	self._bannerSub.Text = sub or ""
	if pop then
		UIKit.pop(self._bannerScale, 1.1)
	end
end

function HUDController.hideBanner(self: HUD)
	self._bannerToken += 1
	self._banner.Visible = false
end

return HUDController
