--!strict
--[[
	VictoryFX  (ModuleScript)  ·  StarterPlayerScripts/Client/VictoryFX

	ROUND_END / GAME_END dressing, all created on this client only and
	destroyed on exit (nothing replicates, nothing leaks between matches):
	  • a warm SpotLight hanging over each winner's seat (SeatAnchorNN of the
	    local player's room, found by MatchPlayer.seat, so bots work too)
	  • GAME_END: case-file paper confetti from a ParticleEmitter above the
	    table (plain square particles in manila / off-white, tumbling; no
	    texture assets)
	  • the victory camera orbits toward the (first) winner's seat
	  • if the LOCAL player won, their own character plays Config.Animations.Cheer
	Bot rigs are never animated from here.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Names = require(ReplicatedStorage.Shared.Names)
local CameraController = require(script.Parent.CameraController)
local LocalAnim = require(script.Parent.LocalAnim)
local State = require(script.Parent.State)

local VictoryFX = {}

local SPOT_HEIGHT = 9
local CONFETTI_HEIGHT = 12
local CONFETTI_BURST = 45
local CONFETTI_RATE = 14
local CHEER_SECONDS = 4

local created: { Instance } = {}
local activeKey: string? = nil
local cheeredKey: string? = nil

local function seatPart(room: Model, seat: number?): BasePart?
	if type(seat) ~= "number" then
		return nil
	end
	local seats = room:FindFirstChild(Names.Seats, true)
	local part = seats and seats:FindFirstChild(Names.SeatAnchor(seat))
	return if part and part:IsA("BasePart") then part else nil
end

local function holderPart(name: string, cframe: CFrame, size: Vector3): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Anchored = true
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false
	part.CastShadow = false
	part.Transparency = 1
	part.Size = size
	part.CFrame = cframe
	return part
end

local function addSpotlight(room: Model, seat: BasePart)
	local part = holderPart("C64WinnerSpot", CFrame.new(seat.Position + Vector3.new(0, SPOT_HEIGHT, 0)), Vector3.new(1, 1, 1))
	local light = Instance.new("SpotLight")
	light.Face = Enum.NormalId.Bottom
	light.Angle = 38
	light.Range = SPOT_HEIGHT + 6
	light.Brightness = 5
	light.Color = Color3.fromRGB(255, 226, 170)
	light.Shadows = true
	light.Parent = part
	part.Parent = room
	table.insert(created, part)
end

local function addConfetti(room: Model)
	local center = room:GetPivot().Position
	local part = holderPart("C64Confetti", CFrame.new(center + Vector3.new(0, CONFETTI_HEIGHT, 0)), Vector3.new(18, 0.2, 16))
	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = "CaseFilePaper"
	emitter.Texture = "rbxasset://textures/particles/sparkles_main.dds" -- built-in texture (ships with Roblox); squashed into paper-slip shapes
	emitter.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(232, 222, 196)),
		ColorSequenceKeypoint.new(0.5, Color3.fromRGB(214, 196, 150)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(240, 236, 226)),
	})
	emitter.Size = NumberSequence.new(0.32)
	emitter.Squash = NumberSequence.new({ -- flutter: the slip flattens and widens as it tumbles
		NumberSequenceKeypoint.new(0, -0.6),
		NumberSequenceKeypoint.new(0.25, 0.6),
		NumberSequenceKeypoint.new(0.5, -0.6),
		NumberSequenceKeypoint.new(0.75, 0.6),
		NumberSequenceKeypoint.new(1, -0.6),
	})
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(0.85, 0),
		NumberSequenceKeypoint.new(1, 1),
	})
	emitter.Lifetime = NumberRange.new(3.5, 5.5)
	emitter.Speed = NumberRange.new(0.5, 2)
	emitter.SpreadAngle = Vector2.new(30, 30)
	emitter.EmissionDirection = Enum.NormalId.Bottom
	emitter.Acceleration = Vector3.new(0, -2.2, 0)
	emitter.Drag = 0.8
	emitter.Rotation = NumberRange.new(0, 360)
	emitter.RotSpeed = NumberRange.new(-200, 200)
	emitter.LightInfluence = 1
	emitter.Rate = CONFETTI_RATE
	emitter.Parent = part
	part.Parent = room
	table.insert(created, part)
	emitter:Emit(CONFETTI_BURST)
end

-- Builds the effects for the current snapshot (idempotent per state/winners).
function VictoryFX.enter()
	local snapshot = State.snapshot
	local room = State.room
	if not snapshot or (snapshot.state ~= "ROUND_END" and snapshot.state ~= "GAME_END") then
		return
	end
	local winners: { number }
	if snapshot.state == "GAME_END" then
		winners = if type(snapshot.winnerUserIds) == "table" then snapshot.winnerUserIds else {}
	else
		winners = if snapshot.roundWinnerUserId then { snapshot.roundWinnerUserId } else {}
	end
	local key = `{snapshot.matchId}:{snapshot.state}:{snapshot.round}:{table.concat(winners, ",")}:{room ~= nil}`
	if key == activeKey then
		return
	end
	VictoryFX.exit()
	activeKey = key

	local focus: Vector3? = nil
	if room then
		for _, id in winners do
			local player = State.playersById[id]
			local seat = player and seatPart(room, player.seat)
			if seat then
				addSpotlight(room, seat)
				focus = focus or seat.Position
			end
		end
		if snapshot.state == "GAME_END" then
			addConfetti(room)
		end
	end
	CameraController.setVictoryFocus(focus)

	local cheerKey = `{snapshot.matchId}:{snapshot.state}:{snapshot.round}`
	if table.find(winners, State.localUserId) and cheeredKey ~= cheerKey then
		cheeredKey = cheerKey
		LocalAnim.play("Cheer", CHEER_SECONDS)
	end
end

-- Destroys everything this module made (state left / match over).
function VictoryFX.exit()
	activeKey = nil
	for _, inst in created do
		inst:Destroy()
	end
	table.clear(created)
	CameraController.setVictoryFocus(nil)
end

-- Number of live client-made effect parts (for diagnostics / tests).
function VictoryFX.count(): number
	local n = 0
	for _, inst in created do
		if inst.Parent then
			n += 1
		end
	end
	return n
end

return VictoryFX
