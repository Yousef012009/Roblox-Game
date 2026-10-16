--!strict
--[[
	QueueHUD  (ModuleScript)  ·  StarterPlayerScripts/Client/QueueHUD

	Lobby-only. While queued: "QUEUE 02 · 3/4", the queue state
	("STARTING 0:04", "DEPARTING", "WAITING FOR A ROOM") and a LEAVE button.
	Otherwise a compact hint: "WALK INTO AN ELEVATOR TO QUEUE".
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local State = require(script.Parent.State)
local UIKit = require(script.Parent.UIKit)

local QueueHUD = {}

local root: Frame
local queuePanel: Frame
local titleLabel: TextLabel
local stateLabel: TextLabel
local leaveButton: TextButton
local hint: TextLabel
local visible = false
local lastSeconds = -1

function QueueHUD.mount(parent: Instance)
	root = UIKit.new("Frame", {
		Name = "QueueHUD",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 6),
		Size = UDim2.new(0.92, 0, 0, 58),
		Visible = false,
		Parent = parent,
	}, { UIKit.sizeLimit(Vector2.new(0, 0), Vector2.new(400, 58)) })

	queuePanel = UIKit.panel({
		Size = UDim2.fromScale(1, 1),
		Visible = false,
		Parent = root,
	})
	titleLabel = UIKit.label({
		Font = UIKit.Fonts.Header,
		TextColor3 = UIKit.Colors.Phosphor,
		TextXAlignment = Enum.TextXAlignment.Left,
		Position = UDim2.fromOffset(10, 4),
		Size = UDim2.new(1, -96, 0, 26),
		Parent = queuePanel,
	}, 22)
	stateLabel = UIKit.label({
		TextColor3 = UIKit.Colors.TextDim,
		TextXAlignment = Enum.TextXAlignment.Left,
		Position = UDim2.fromOffset(10, 32),
		Size = UDim2.new(1, -96, 0, 20),
		Parent = queuePanel,
	}, 15)
	leaveButton = UIKit.button({
		Text = "LEAVE",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -7, 0.5, 0),
		Size = UDim2.fromOffset(76, UIKit.TouchMin),
		Parent = queuePanel,
	}, UIKit.Colors.Red, 16)
	leaveButton.Activated:Connect(function()
		if leaveButton.Active then
			Remotes.LeaveQueue:FireServer()
			UIKit.setEnabled(leaveButton, false)
			-- Re-arm in case the server refused (e.g. departing): membership updates re-arm too.
			task.delay(1.5, UIKit.setEnabled, leaveButton, true)
		end
	end)

	hint = UIKit.label({
		Text = "WALK INTO AN ELEVATOR TO QUEUE",
		TextColor3 = UIKit.Colors.TextDim,
		BackgroundColor3 = UIKit.Colors.Panel,
		BackgroundTransparency = 0.45,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 0),
		Size = UDim2.new(1, 0, 0, 24),
		Parent = root,
	}, 14)
end

local function stateText(index: number): string
	local status = State.queues[index]
	if not status then
		return "WAITING"
	end
	if status.state == "Starting" then
		local startsAt = status.startsAt
		if startsAt then
			return `STARTING {UIKit.clock(startsAt - State.now())}`
		end
		return "STARTING"
	elseif status.state == "Departing" then
		return "DEPARTING"
	elseif status.state == "WaitingForRoom" then
		return "WAITING FOR A ROOM"
	end
	return "WAITING FOR PLAYERS"
end

-- Called whenever queue status or membership changes.
function QueueHUD.update()
	local index = State.queueIndex
	UIKit.setVisible(queuePanel, index ~= nil)
	UIKit.setVisible(hint, index == nil)
	lastSeconds = -1
	if index then
		local status = State.queues[index]
		local count = if status then status.count else 0
		local capacity = if status then status.capacity else Config.Queue.Capacity
		UIKit.setText(titleLabel, string.format("QUEUE %02d  ·  %d/%d", index, count, capacity))
		UIKit.setText(stateLabel, stateText(index))
		local departing = status ~= nil and status.state == "Departing"
		UIKit.setEnabled(leaveButton, not departing)
	end
end

function QueueHUD.setVisible(on: boolean)
	visible = on
	UIKit.setVisible(root, on)
	if on then
		QueueHUD.update()
	end
end

-- Countdown text only changes once per second.
function QueueHUD.step()
	local index = State.queueIndex
	if not visible or not index then
		return
	end
	local status = State.queues[index]
	if not status or status.state ~= "Starting" or not status.startsAt then
		return
	end
	local seconds = math.max(0, math.ceil(status.startsAt - State.now()))
	if seconds ~= lastSeconds then
		lastSeconds = seconds
		UIKit.setText(stateLabel, stateText(index))
	end
end

return QueueHUD
