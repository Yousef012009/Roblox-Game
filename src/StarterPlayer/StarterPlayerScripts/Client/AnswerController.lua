--!strict
--[[
	AnswerController  (ModuleScript)  ·  StarterPlayerScripts/Client/AnswerController

	The floating bottom-centre answer box. This is the ONLY place answers are
	typed (never the Roblox chat).

	           ┌───────────────┐
	           │ ⏭ SKIP · R$25 │                ← Skip Turn (token or Robux)
	  ┌────────┴───────────────┴──────────────┐
	  │  Type your answer…          [ SEND ]  │  ← amber glow on your turn
	  └───────────────────────────────────────┘

	  • On your turn: auto-focus (pops the phone keyboard), live typing is
	    streamed to the server, which filters it and shows it on the TV.
	  • Enter / the phone's "Done" key or SEND submits.
	  • Validated locally first (WordRules) for instant feedback; the server
	    re-checks everything.
	  • Off-turn: dimmed, read-only, says whose turn it is.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local WordRules = require(Shared:WaitForChild("WordRules"))
local UIKit = require(script.Parent.UIKit)

local C = UIKit.Colors
local F = UIKit.Fonts

local AnswerController = {}
AnswerController.__index = AnswerController

export type AnswerController = typeof(setmetatable(
	{} :: {
		_dock: Frame,
		_stroke: UIStroke,
		_box: TextBox,
		_send: TextButton,
		_skip: TextButton,
		_error: TextLabel,
		_turn: Remotes.TurnInfo?,
		_awaiting: boolean,
		_dirty: boolean,
		_seq: number,
		_lastSent: number,
		_skipLabel: () -> string?,
	},
	AnswerController
))

-- `skipLabel` returns e.g. "×2" / "R$25", or nil when Skip is disabled.
function AnswerController.new(screen: ScreenGui, skipLabel: () -> string?): AnswerController
	local self = setmetatable({}, AnswerController) :: any
	self._awaiting = false
	self._dirty = false
	self._seq = 0
	self._lastSent = 0
	self._skipLabel = skipLabel

	self._dock = UIKit.panel({
		Name = "AnswerDock",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -14),
		Size = UDim2.new(0.62, 0, 0, 60),
		Visible = false,
		Parent = screen,
	}, 16)
	UIKit.sizeLimit(Vector2.new(300, 52), Vector2.new(620, 64)).Parent = self._dock
	self._stroke = self._dock:FindFirstChildOfClass("UIStroke") :: UIStroke

	self._box = UIKit.create("TextBox", {
		Name = "Input",
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 14, 0.5, 0),
		Size = UDim2.new(1, -124, 1, -14),
		BackgroundTransparency = 1,
		ClearTextOnFocus = false,
		TextEditable = false,
		Font = F.Body,
		PlaceholderText = "Wait for your turn…",
		PlaceholderColor3 = C.Muted,
		Text = "",
		TextColor3 = C.Paper,
		TextScaled = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = self._dock,
	}, { UIKit.textSize(26, 14) })

	self._send = UIKit.button({
		Name = "Send",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -7, 0.5, 0),
		Size = UDim2.new(0, 96, 1, -14),
		Text = "SEND",
		Parent = self._dock,
	})

	self._skip = UIKit.button({
		Name = "Skip",
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(1, -4, 0, -8),
		Size = UDim2.fromOffset(150, 36),
		Text = "⏭ SKIP",
		Visible = false,
		Parent = self._dock,
	}, C.Blue, C.Ink)

	self._error = UIKit.label({
		Name = "Error",
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 6, 0, -10),
		Size = UDim2.new(1, -170, 0, 22),
		TextColor3 = C.Red,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = self._dock,
	}, 18)
	UIKit.create("UIStroke", { Color = C.Ink, Thickness = 2, Parent = self._error })

	-- Live typing: cap the length and mark the draft dirty.
	self._box:GetPropertyChangedSignal("Text"):Connect(function()
		local text = self._box.Text
		local capped = WordRules.truncate(text, Config.Words.MaxLength)
		if capped ~= text then
			self._box.Text = capped
			return
		end
		if self._turn and not self._awaiting then
			self._dirty = true
			self._error.Text = ""
		end
	end)

	self._box.FocusLost:Connect(function(enterPressed: boolean)
		if enterPressed then
			self:submit()
		end
	end)
	self._send.Activated:Connect(function()
		self:submit()
	end)
	self._skip.Activated:Connect(function()
		if self._turn then
			Remotes.RequestPurchase:FireServer("SkipTurn")
		end
	end)
	return self
end

function AnswerController.setVisible(self: AnswerController, visible: boolean)
	self._dock.Visible = visible
	if not visible then
		self._box:ReleaseFocus()
	end
end

-- It's my turn.
function AnswerController.enable(self: AnswerController, turn: Remotes.TurnInfo)
	self._turn = turn
	self._awaiting = false
	self._dirty = false
	self._box.Text = ""
	self._box.TextEditable = true
	self._box.PlaceholderText = "Type your answer…"
	self._error.Text = ""
	self._send.Text = "SEND"
	self._send.BackgroundColor3 = C.Amber
	self._stroke.Color = C.Amber
	self._stroke.Thickness = 2.5
	self._stroke.Transparency = 0
	self:refreshSkip()
	self._box:CaptureFocus() -- pops the keyboard on phones
end

-- Not my turn (or my turn just ended).
function AnswerController.disable(self: AnswerController, placeholder: string?)
	self._turn = nil
	self._awaiting = false
	self._dirty = false
	self._box:ReleaseFocus()
	self._box.TextEditable = false
	self._box.Text = ""
	self._box.PlaceholderText = placeholder or "Wait for your turn…"
	self._send.BackgroundColor3 = C.InkSoft
	self._send.Text = "SEND"
	self._stroke.Color = C.Line
	self._stroke.Thickness = 1.5
	self._stroke.Transparency = 0.2
	self._skip.Visible = false
end

function AnswerController.refreshSkip(self: AnswerController)
	local label = self._skipLabel()
	self._skip.Visible = self._turn ~= nil and label ~= nil
	if label then
		self._skip.Text = `⏭ SKIP · {label}`
	end
end

function AnswerController.submit(self: AnswerController)
	if not self._turn or self._awaiting then
		return
	end
	local ok, cleanedOrReason = WordRules.validate(self._box.Text)
	if not ok then
		self:reject(cleanedOrReason)
		return
	end
	self._awaiting = true
	self._box.TextEditable = false
	self._send.Text = "…"
	Remotes.SubmitAnswer:FireServer(self._box.Text)
end

-- Server (or local validation) said no. The timer keeps running, so try again.
function AnswerController.reject(self: AnswerController, reason: string)
	self._awaiting = false
	self._error.Text = reason
	self._send.Text = "SEND"
	if self._turn then
		self._box.TextEditable = true
		self._box:CaptureFocus()
	end
end

-- Called every frame: streams the draft at most every ClientSendInterval.
function AnswerController.update(self: AnswerController)
	if not self._turn or not self._dirty or self._awaiting then
		return
	end
	local now = os.clock()
	if now - self._lastSent < Config.Typing.ClientSendInterval then
		return
	end
	self._dirty = false
	self._lastSent = now
	self._seq += 1
	Remotes.TypingUpdate:FireServer(self._seq, self._box.Text)
end

return AnswerController
