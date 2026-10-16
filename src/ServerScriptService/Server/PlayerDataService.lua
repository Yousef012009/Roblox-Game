--!strict
--[[
	PlayerDataService  (ModuleScript)  ·  ServerScriptService/Server/PlayerDataService

	Saves each player's purchase tokens and wins in a DataStore.

	DESIGN: every Developer Product purchase becomes a saved TOKEN:
	    SkipTurn · Revive · ForceCaller
	The game spends a token the moment it can be used. That gives two
	guarantees:
	  1. A player NEVER loses Robux. If a receipt arrives too late (the turn
	     already ended, the server lagged), the token is kept for next time.
	  2. ProcessReceipt can be idempotent. The token is added and the
	     PurchaseId recorded in ONE atomic UpdateAsync, so a re-delivered
	     receipt can never grant twice.

	Spending tokens and adding wins happen in memory straight away. They are
	saved as *deltas* (+1 win, -1 Skip) every Config.Data.AutoSaveSeconds and
	when the player leaves. Deltas commute, so they merge safely with receipt
	grants written by other code paths.

	Studio with "API Services" off, or an unpublished place, falls back to
	memory-only mode automatically, so testing still works.

	Production note: for big games consider ProfileStore (session locking).
	Without it, a player hopping servers within a few seconds could briefly
	see a token they already spent on the old server.
]]

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)

export type TokenKey = "SkipTurn" | "Revive" | "ForceCaller"
export type Profile = {
	Tokens: { [string]: number },
	Wins: number,
}

type SaveData = {
	Tokens: { [string]: number },
	Wins: number,
	Receipts: { string },
	Version: number,
}

type Delta = {
	Tokens: { [string]: number },
	Wins: number,
}

local TOKEN_KEYS: { TokenKey } = { "SkipTurn", "Revive", "ForceCaller" }

local PlayerDataService = {}

local changedEvent = Instance.new("BindableEvent")
-- Fires (player: Player) whenever that player's cached profile changes.
PlayerDataService.Changed = changedEvent.Event

local store: DataStore? = nil
local memoryOnly = false
local memoryStore: { [number]: any } = {} -- stands in for the DataStore in memory-only mode

local profiles: { [Player]: Profile } = {}
local pending: { [number]: Delta } = {}

----------------------------------------------------------------------------
-- Internals
----------------------------------------------------------------------------
local function switchToMemoryOnly(reason: string)
	if not memoryOnly then
		memoryOnly = true
		warn(`[PlayerData] DataStores unavailable ({reason}). Using MEMORY-ONLY mode: nothing will be saved.`)
	end
end

if game.PlaceId == 0 then
	switchToMemoryOnly("place is not published")
else
	local ok, result = pcall(function()
		return DataStoreService:GetDataStore(Config.Data.StoreName)
	end)
	if ok then
		store = result
	else
		switchToMemoryOnly(tostring(result))
	end
end

local function keyFor(userId: number): string
	return `u_{userId}`
end

-- Turn whatever is stored (nil, old format, corrupted) into a valid SaveData.
local function reconcile(raw: any): SaveData
	local data: any = if type(raw) == "table" then raw else {}
	data.Tokens = if type(data.Tokens) == "table" then data.Tokens else {}
	for _, key in TOKEN_KEYS do
		data.Tokens[key] = math.max(0, math.floor(tonumber(data.Tokens[key]) or 0))
	end
	data.Wins = math.max(0, math.floor(tonumber(data.Wins) or 0))
	data.Receipts = if type(data.Receipts) == "table" then data.Receipts else {}
	data.Version = 1
	return data :: SaveData
end

local function isAccessError(err: any): boolean
	local message = tostring(err)
	return string.find(message, "StudioAccessToApisNotAllowed", 1, true) ~= nil
		or string.find(message, "403", 1, true) ~= nil
end

-- Atomic read-modify-write with retries. `transform` may run several times
-- and may return nil to cancel the write. Returns success.
local function update(userId: number, transform: (SaveData) -> SaveData?): boolean
	if not memoryOnly and store then
		for attempt = 1, 3 do
			local ok, err = pcall(function()
				(store :: DataStore):UpdateAsync(keyFor(userId), function(old)
					return transform(reconcile(old))
				end)
			end)
			if ok then
				return true
			end
			if isAccessError(err) then
				switchToMemoryOnly(tostring(err))
				break
			end
			warn(`[PlayerData] UpdateAsync failed for {userId} (attempt {attempt}):`, err)
			task.wait(attempt * 1.5)
		end
		if not memoryOnly then
			return false
		end
	end

	local result = transform(reconcile(memoryStore[userId]))
	if result then
		memoryStore[userId] = result
	end
	return true
end

local function read(userId: number): (boolean, SaveData)
	if not memoryOnly and store then
		for attempt = 1, 3 do
			local ok, result = pcall(function()
				return (store :: DataStore):GetAsync(keyFor(userId))
			end)
			if ok then
				return true, reconcile(result)
			end
			if isAccessError(result) then
				switchToMemoryOnly(tostring(result))
				break
			end
			warn(`[PlayerData] GetAsync failed for {userId} (attempt {attempt}):`, result)
			task.wait(attempt * 1.5)
		end
		if not memoryOnly then
			return false, reconcile(nil)
		end
	end
	return true, reconcile(memoryStore[userId])
end

local function addDelta(userId: number, tokenKey: string?, tokenDelta: number, winsDelta: number)
	local delta = pending[userId]
	if not delta then
		delta = { Tokens = {}, Wins = 0 }
		pending[userId] = delta
	end
	if tokenKey then
		delta.Tokens[tokenKey] = (delta.Tokens[tokenKey] or 0) + tokenDelta
	end
	delta.Wins += winsDelta
end

-- Save one player's queued deltas. Safe to call any time.
local function flush(userId: number): boolean
	local delta = pending[userId]
	if not delta then
		return true
	end
	pending[userId] = nil

	local ok = update(userId, function(data)
		for key, amount in delta.Tokens do
			data.Tokens[key] = math.max(0, (data.Tokens[key] or 0) + amount)
		end
		data.Wins += delta.Wins
		return data
	end)

	if not ok then
		-- Put it back so the next autosave retries it.
		for key, amount in delta.Tokens do
			addDelta(userId, key, amount, 0)
		end
		addDelta(userId, nil, 0, delta.Wins)
	end
	return ok
end

----------------------------------------------------------------------------
-- Public API
----------------------------------------------------------------------------

-- Load (yields). Call once from PlayerAdded.
function PlayerDataService.load(player: Player): Profile?
	local ok, data = read(player.UserId)
	if not ok then
		warn(`[PlayerData] Could not load {player.Name}; they start empty this session (saved data is untouched).`)
	end
	if player.Parent == nil then
		return nil -- left while loading
	end

	-- Deltas the player built up earlier in this same server (rejoin) still apply.
	local delta = pending[player.UserId]
	if delta then
		for key, amount in delta.Tokens do
			data.Tokens[key] = math.max(0, (data.Tokens[key] or 0) + amount)
		end
		data.Wins += delta.Wins
	end

	local profile: Profile = { Tokens = table.clone(data.Tokens), Wins = data.Wins }
	profiles[player] = profile
	changedEvent:Fire(player)
	return profile
end

function PlayerDataService.get(player: Player): Profile?
	return profiles[player]
end

-- Yields until the profile is loaded or `timeout` seconds pass.
function PlayerDataService.waitForProfile(player: Player, timeout: number): Profile?
	local deadline = os.clock() + timeout
	while not profiles[player] and player.Parent ~= nil and os.clock() < deadline do
		task.wait(0.1)
	end
	return profiles[player]
end

function PlayerDataService.getTokens(player: Player, key: TokenKey): number
	local profile = profiles[player]
	return if profile then profile.Tokens[key] or 0 else 0
end

-- Spend one token. Returns false if the player has none.
function PlayerDataService.consumeToken(player: Player, key: TokenKey): boolean
	local profile = profiles[player]
	if not profile or (profile.Tokens[key] or 0) < 1 then
		return false
	end
	profile.Tokens[key] -= 1
	addDelta(player.UserId, key, -1, 0)
	changedEvent:Fire(player)
	return true
end

function PlayerDataService.addWin(player: Player)
	local profile = profiles[player]
	if not profile then
		return
	end
	profile.Wins += 1
	addDelta(player.UserId, nil, 0, 1)
	changedEvent:Fire(player)
end

--[[
	Grant a purchased token to `userId`. Yields. This is called from
	ProcessReceipt.

	Returns (success, newlyGranted):
	  success = false → saving failed; return NotProcessedYet so Roblox retries
	  newlyGranted = false → this PurchaseId was already granted earlier
]]
function PlayerDataService.grantPurchase(userId: number, purchaseId: string, key: TokenKey): (boolean, boolean)
	local player = Players:GetPlayerByUserId(userId)
	if player then
		-- Make sure the cache exists first, so the +1 below is not lost.
		PlayerDataService.waitForProfile(player, 15)
	end

	local newlyGranted = false
	local ok = update(userId, function(data)
		if table.find(data.Receipts, purchaseId) then
			newlyGranted = false
			return nil -- already granted, so cancel the write
		end
		newlyGranted = true
		data.Tokens[key] = (data.Tokens[key] or 0) + 1
		table.insert(data.Receipts, purchaseId)
		while #data.Receipts > Config.Data.MaxStoredReceipts do
			table.remove(data.Receipts, 1)
		end
		return data
	end)

	if not ok then
		return false, false
	end

	if newlyGranted and player then
		local profile = profiles[player]
		if profile then
			profile.Tokens[key] = (profile.Tokens[key] or 0) + 1
			changedEvent:Fire(player)
		end
	end
	return true, newlyGranted
end

-- Call from PlayerRemoving: saves and drops the cache.
function PlayerDataService.release(player: Player)
	profiles[player] = nil
	task.spawn(flush, player.UserId)
end

function PlayerDataService.isMemoryOnly(): boolean
	return memoryOnly
end

----------------------------------------------------------------------------
-- Autosave + shutdown
----------------------------------------------------------------------------
task.spawn(function()
	while true do
		task.wait(Config.Data.AutoSaveSeconds)
		for userId in table.clone(pending) do
			task.spawn(flush, userId)
		end
	end
end)

game:BindToClose(function()
	local remaining = 0
	for userId in table.clone(pending) do
		remaining += 1
		task.spawn(function()
			flush(userId)
			remaining -= 1
		end)
	end
	local deadline = os.clock() + 25
	while remaining > 0 and os.clock() < deadline do
		task.wait(0.1)
	end
end)

return PlayerDataService
