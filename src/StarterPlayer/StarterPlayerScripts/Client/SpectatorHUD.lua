--!strict
--[[
	SpectatorHUD  (ModuleScript)  ·  StarterPlayerScripts/Client/SpectatorHUD

	Shown while the local player's status is Eliminated: a bottom bar with
	"SPECTATING - BEHIND THE MIRROR", the current answer/category line, who
	is still in play (up to 8 names, compact, bots tagged AI) and
	previous/next camera buttons (cycling the room's spectator anchors).
]]

local CameraController = require(script.Parent.CameraController)
local State = require(script.Parent.State)
local UIKit = require(script.Parent.UIKit)

local SpectatorHUD = {}

local root: Frame
local infoLabel: TextLabel
local aliveLabel: TextLabel
local camLabel: TextLabel
local visible = false

local function refreshCam()
	UIKit.setText(camLabel, CameraController.spectatorLabel())
end

function SpectatorHUD.mount(parent: Instance)
	root = UIKit.panel({
		Name = "SpectatorHUD",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -8),
		Size = UDim2.new(0.96, 0, 0, 84),
		Visible = false,
		ZIndex = 8,
		Parent = parent,
	})
	UIKit.sizeLimit(Vector2.new(0, 0), Vector2.new(640, 84)).Parent = root

	local prev = UIKit.button({
		Text = "<",
		Position = UDim2.fromOffset(8, 10),
		Size = UDim2.fromOffset(UIKit.TouchMin, UIKit.TouchMin),
		ZIndex = 9,
		Parent = root,
	}, UIKit.Colors.Text, 22)
	local nextButton = UIKit.button({
		Text = ">",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -8, 0, 10),
		Size = UDim2.fromOffset(UIKit.TouchMin, UIKit.TouchMin),
		ZIndex = 9,
		Parent = root,
	}, UIKit.Colors.Text, 22)
	prev.Activated:Connect(function()
		CameraController.cycleSpectator(-1)
		refreshCam()
	end)
	nextButton.Activated:Connect(function()
		CameraController.cycleSpectator(1)
		refreshCam()
	end)

	UIKit.label({
		Text = "SPECTATING - BEHIND THE MIRROR",
		Font = UIKit.Fonts.Header,
		TextColor3 = UIKit.Colors.Red,
		TextXAlignment = Enum.TextXAlignment.Left,
		Position = UDim2.fromOffset(62, 6),
		Size = UDim2.new(1, -196, 0, 24),
		ZIndex = 9,
		Parent = root,
	}, 18, 9)
	camLabel = UIKit.label({
		TextColor3 = UIKit.Colors.TextDim,
		TextXAlignment = Enum.TextXAlignment.Right,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -62, 0, 6),
		Size = UDim2.fromOffset(72, 24),
		ZIndex = 9,
		Parent = root,
	}, 14)
	infoLabel = UIKit.label({
		TextColor3 = UIKit.Colors.Text,
		TextXAlignment = Enum.TextXAlignment.Left,
		Position = UDim2.fromOffset(62, 32),
		Size = UDim2.new(1, -124, 0, 22),
		ZIndex = 9,
		Parent = root,
	}, 15)
	aliveLabel = UIKit.label({
		RichText = true,
		TextColor3 = UIKit.Colors.TextDim,
		TextXAlignment = Enum.TextXAlignment.Left,
		Position = UDim2.fromOffset(62, 56),
		Size = UDim2.new(1, -124, 0, 20),
		ZIndex = 9,
		Parent = root,
	}, 13, 7)
end

-- "IN PLAY 5/8: AVA · MORSE AI · ..." (the Caller is marked, bots tagged).
local function aliveText(snapshot: State.Snapshot): string
	local names = {}
	local total = 0
	local players: { State.MatchPlayer } = if type(snapshot.players) == "table" then snapshot.players else {}
	for _, player in players do
		total += 1
		if player.status == "Active" then
			local name = UIKit.escape(string.upper(player.name or "?"))
			if player.isBot then
				name ..= ` <font color="#d2a85c">AI</font>`
			end
			if player.userId == snapshot.callerUserId then
				name = `<font color="#d2a85c">{name}</font>`
			end
			table.insert(names, name)
		end
	end
	return `IN PLAY {#names}/{total}: {table.concat(names, " · ")}`
end

function SpectatorHUD.update()
	local snapshot = State.snapshot
	if not visible or not snapshot then
		return
	end
	local category = if snapshot.category then string.upper(snapshot.category) else "-"
	local info
	if snapshot.judging then
		info = `{category}  ·  {State.tagName(snapshot.judging.userId)}: "{snapshot.judging.answer}"`
	elseif snapshot.turn then
		info = `{category}  ·  {State.tagName(snapshot.turn.userId)} IS ANSWERING`
	else
		local accepted = snapshot.accepted
		local last = if accepted and #accepted > 0 then accepted[#accepted] else nil
		info = if last then `{category}  ·  LAST: "{last.answer}"` else category
	end
	UIKit.setText(infoLabel, info)
	UIKit.setText(aliveLabel, aliveText(snapshot))
	refreshCam()
end

function SpectatorHUD.setVisible(on: boolean)
	if on == visible then
		if on then
			SpectatorHUD.update()
		end
		return
	end
	visible = on
	if on then
		UIKit.reveal(root, 12)
		SpectatorHUD.update()
	else
		root.Visible = false
	end
end

return SpectatorHUD
