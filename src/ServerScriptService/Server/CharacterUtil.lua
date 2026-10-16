--!strict
--[[
	CharacterUtil  (ModuleScript)  ·  ServerScriptService/Server/CharacterUtil

	Small, nil-safe character helpers shared by QueueService and Match.
	Every function tolerates a missing character / humanoid / root part and
	simply does nothing (returning false where a result is useful), because
	characters can vanish at any moment (death, respawn, disconnect).

	    CharacterUtil.seat(player, seat)        PivotTo above the seat, then Seat:Sit
	    CharacterUtil.teleport(player, cframe)  unseat, then PivotTo cframe + 3 studs up
	    CharacterUtil.lockMovement(player)      WalkSpeed / JumpPower / JumpHeight = 0
	    CharacterUtil.unlockMovement(player)    restore the StarterPlayer defaults
]]

local StarterPlayer = game:GetService("StarterPlayer")

local CharacterUtil = {}

local SEAT_DROP_HEIGHT = 2.5 -- studs above the seat before Sit, so the SeatWeld snaps cleanly
local TELEPORT_LIFT = 3 -- studs above the target so the character never spawns inside a floor
local SEAT_WELD_NAME = "SeatWeld" -- engine-created weld between a Seat and the sitting HumanoidRootPart

function CharacterUtil.getHumanoid(player: Player): Humanoid?
	local character = player.Character
	if not character then
		return nil
	end
	return character:FindFirstChildOfClass("Humanoid")
end

function CharacterUtil.getRoot(player: Player): BasePart?
	local character = player.Character
	if not character then
		return nil
	end
	local root = character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return root
	end
	return nil
end

-- True when the player has a character in the world with a living humanoid and a root part.
function CharacterUtil.isAlive(player: Player): boolean
	local character = player.Character
	if not character or not character.Parent then
		return false
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return false
	end
	return CharacterUtil.getRoot(player) ~= nil
end

-- Waits (up to `timeout` seconds) for a freshly spawned character's root part.
function CharacterUtil.waitForRoot(character: Model, timeout: number): BasePart?
	local root = character:WaitForChild("HumanoidRootPart", timeout)
	if root and root:IsA("BasePart") then
		return root
	end
	return nil
end

-- Breaks whatever seat currently holds `humanoid`.
function CharacterUtil.unseatHumanoid(humanoid: Humanoid)
	local seatPart = humanoid.SeatPart
	if seatPart then
		local weld = seatPart:FindFirstChild(SEAT_WELD_NAME)
		if weld then
			weld:Destroy()
		end
	end
	humanoid.Sit = false
end

function CharacterUtil.unseat(player: Player)
	local humanoid = CharacterUtil.getHumanoid(player)
	if humanoid then
		CharacterUtil.unseatHumanoid(humanoid)
	end
end

-- Moves the character to `cframe` (3 studs higher). Unseats first: a seated
-- character is welded to its seat and PivotTo would drag the seat along.
function CharacterUtil.teleport(player: Player, cframe: CFrame): boolean
	local character = player.Character
	if not character or not character.Parent then
		return false
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		CharacterUtil.unseatHumanoid(humanoid)
	end
	character:PivotTo(cframe + Vector3.new(0, TELEPORT_LIFT, 0))
	return true
end

-- Sits the player in `seat`. Anyone else occupying it is ejected first (match
-- seats belong to exactly one player). Returns false if the player has no
-- living character.
function CharacterUtil.seat(player: Player, seat: Seat): boolean
	local character = player.Character
	local humanoid = CharacterUtil.getHumanoid(player)
	if not character or not character.Parent or not humanoid or humanoid.Health <= 0 then
		return false
	end
	if seat.Occupant == humanoid then
		return true
	end
	local intruder = seat.Occupant
	if intruder then
		CharacterUtil.unseatHumanoid(intruder)
	end
	CharacterUtil.unseatHumanoid(humanoid)
	-- Keep the seat's rotation so the character faces the way the seat faces.
	character:PivotTo(seat.CFrame + Vector3.new(0, SEAT_DROP_HEIGHT, 0))
	seat:Sit(humanoid)
	return true
end

function CharacterUtil.lockMovement(player: Player)
	local humanoid = CharacterUtil.getHumanoid(player)
	if not humanoid then
		return
	end
	humanoid.WalkSpeed = 0
	humanoid.JumpPower = 0
	humanoid.JumpHeight = 0
end

function CharacterUtil.unlockMovement(player: Player)
	local humanoid = CharacterUtil.getHumanoid(player)
	if not humanoid then
		return
	end
	humanoid.WalkSpeed = StarterPlayer.CharacterWalkSpeed
	humanoid.JumpPower = StarterPlayer.CharacterJumpPower
	humanoid.JumpHeight = StarterPlayer.CharacterJumpHeight
end

return CharacterUtil
