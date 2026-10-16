--!strict
--[[
	MonetizationService  (ModuleScript)  ·  ServerScriptService/Server/MonetizationService

	Everything Robux-related lives here:

	  • ProcessReceipt for the three Developer Products. Each purchase becomes
	    a saved token through PlayerDataService (atomic and idempotent).
	  • Game Pass ownership for Custom Category (cached at join, updated live
	    when bought in-game).
	  • Server-side purchase prompts. The client never calls
	    PromptProductPurchase itself: it asks the server (Remotes.RequestPurchase),
	    GameManager checks the request is legal right now, and this module opens
	    the prompt and tracks it. Because the server knows a dialog is open, it
	    can hold the turn or bribe deadline until the player finishes paying
	    (see isPurchaseInFlight).
	  • The Force Caller "armed" queue (who has asked to call next round).

	GameManager listens to `TokenGranted` and applies a fresh purchase straight
	away (skip the turn, revive, arm Force Caller). If it no longer applies,
	the token simply stays in the player's wallet for later.
]]

local HttpService = game:GetService("HttpService")
local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Config = require(ReplicatedStorage.Shared.Config)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local PlayerDataService = require(script.Parent.PlayerDataService)

export type ProductKey = PlayerDataService.TokenKey

local MonetizationService = {}

local tokenGrantedEvent = Instance.new("BindableEvent")
-- Fires (player: Player, key: ProductKey) right after a purchase is saved.
MonetizationService.TokenGranted = tokenGrantedEvent.Event

local passGrantedEvent = Instance.new("BindableEvent")
-- Fires (player: Player) when the Custom Category pass is bought in-game.
MonetizationService.CustomCategoryUnlocked = passGrantedEvent.Event

type PromptState = {
	key: string,
	openedAt: number,
	closedAt: number?,
	purchased: boolean,
	granted: boolean,
}

local ownsCustomCategory: { [Player]: boolean } = {}
local prompts: { [Player]: PromptState } = {}
local armedQueue: { Player } = {} -- Force Caller, in the order players armed it

local productKeyById: { [number]: ProductKey } = {}
for key, id in Config.Products :: { [string]: number } do
	if id ~= 0 then
		productKeyById[id] = key :: ProductKey
	end
end

local function simulating(): boolean
	return RunService:IsStudio() and Config.Debug.SimulateMissingProductsInStudio
end

local function productId(key: ProductKey): number
	return (Config.Products :: { [string]: number })[key] or 0
end

----------------------------------------------------------------------------
-- Queries
----------------------------------------------------------------------------
function MonetizationService.isProductEnabled(key: ProductKey): boolean
	return productId(key) ~= 0 or simulating()
end

function MonetizationService.isCustomCategoryEnabled(): boolean
	return Config.GamePasses.CustomCategory ~= 0 or simulating()
end

function MonetizationService.hasCustomCategory(player: Player): boolean
	return ownsCustomCategory[player] == true
end

function MonetizationService.getTokens(player: Player, key: ProductKey): number
	return PlayerDataService.getTokens(player, key)
end

function MonetizationService.consumeToken(player: Player, key: ProductKey): boolean
	return PlayerDataService.consumeToken(player, key)
end

--[[
	True while a server-opened purchase dialog for `key` is still on screen
	(capped at Config.Purchases.PromptHoldMaxSeconds), or was just accepted
	and its receipt has not arrived yet (capped at ReceiptWaitSeconds).
	GameManager uses this to hold timeouts instead of punishing a paying player.
]]
function MonetizationService.isPurchaseInFlight(player: Player, key: ProductKey): boolean
	local prompt = prompts[player]
	if not prompt or prompt.key ~= key or prompt.granted then
		return false
	end
	local now = os.clock()
	local closedAt = prompt.closedAt
	if closedAt == nil then
		return now - prompt.openedAt < Config.Purchases.PromptHoldMaxSeconds
	end
	return prompt.purchased and now - closedAt < Config.Purchases.ReceiptWaitSeconds
end

----------------------------------------------------------------------------
-- Wallet (client mirror)
----------------------------------------------------------------------------
function MonetizationService.getWallet(player: Player): Remotes.Wallet
	return {
		Tokens = {
			SkipTurn = PlayerDataService.getTokens(player, "SkipTurn"),
			Revive = PlayerDataService.getTokens(player, "Revive"),
			ForceCaller = PlayerDataService.getTokens(player, "ForceCaller"),
		},
		Enabled = {
			SkipTurn = MonetizationService.isProductEnabled("SkipTurn"),
			Revive = MonetizationService.isProductEnabled("Revive"),
			ForceCaller = MonetizationService.isProductEnabled("ForceCaller"),
			CustomCategory = MonetizationService.isCustomCategoryEnabled(),
		},
		HasCustomCategory = MonetizationService.hasCustomCategory(player),
		ForceCallerArmed = table.find(armedQueue, player) ~= nil,
	}
end

function MonetizationService.pushWallet(player: Player)
	if player.Parent then
		Remotes.WalletChanged:FireClient(player, MonetizationService.getWallet(player))
	end
end

----------------------------------------------------------------------------
-- Force Caller queue
----------------------------------------------------------------------------
function MonetizationService.isForceCallerArmed(player: Player): boolean
	return table.find(armedQueue, player) ~= nil
end

function MonetizationService.setForceCallerArmed(player: Player, armed: boolean)
	local index = table.find(armedQueue, player)
	if armed and not index then
		table.insert(armedQueue, player)
	elseif not armed and index then
		table.remove(armedQueue, index)
	end
	MonetizationService.pushWallet(player)
end

-- 1-based position in the armed queue (nil if not armed).
function MonetizationService.armedRank(player: Player): number?
	return table.find(armedQueue, player)
end

function MonetizationService.armedPlayers(): { Player }
	return table.clone(armedQueue)
end

----------------------------------------------------------------------------
-- Prompting
----------------------------------------------------------------------------
local function markGranted(player: Player, key: ProductKey)
	local prompt = prompts[player]
	if prompt and prompt.key == key then
		prompt.granted = true
	end
end

local function grantSimulated(player: Player, key: ProductKey)
	local ok, newlyGranted = PlayerDataService.grantPurchase(player.UserId, "SIM-" .. HttpService:GenerateGUID(false), key)
	if ok and newlyGranted and player.Parent then
		markGranted(player, key)
		tokenGrantedEvent:Fire(player, key)
	end
end

-- Opens the Robux dialog for a Developer Product (server-side).
function MonetizationService.promptProduct(player: Player, key: ProductKey)
	local id = productId(key)
	prompts[player] = { key = key, openedAt = os.clock(), purchased = false, granted = false }

	if id == 0 then
		if simulating() then
			-- Studio stand-in for a real purchase dialog.
			Remotes.Notify:FireClient(player, `[Studio] Simulated purchase: {key}`, "Info")
			task.delay(0.75, function()
				local prompt = prompts[player]
				if prompt and prompt.key == key then
					prompt.closedAt = os.clock()
					prompt.purchased = true
				end
				grantSimulated(player, key)
			end)
		else
			prompts[player] = nil
		end
		return
	end

	local ok, err = pcall(function()
		MarketplaceService:PromptProductPurchase(player, id)
	end)
	if not ok then
		prompts[player] = nil
		warn("[Monetization] PromptProductPurchase failed:", err)
	end
end

-- Opens the Robux dialog for the Custom Category Game Pass.
function MonetizationService.promptCustomCategory(player: Player)
	if ownsCustomCategory[player] then
		return
	end
	local id = Config.GamePasses.CustomCategory
	if id == 0 then
		if simulating() then
			ownsCustomCategory[player] = true
			Remotes.Notify:FireClient(player, "[Studio] Simulated pass: Custom Category", "Info")
			MonetizationService.pushWallet(player)
			passGrantedEvent:Fire(player)
		end
		return
	end
	local ok, err = pcall(function()
		MarketplaceService:PromptGamePassPurchase(player, id)
	end)
	if not ok then
		warn("[Monetization] PromptGamePassPurchase failed:", err)
	end
end

----------------------------------------------------------------------------
-- Receipts
----------------------------------------------------------------------------
local function processReceipt(receipt: any): Enum.ProductPurchaseDecision
	local key: ProductKey? = productKeyById[receipt.ProductId]
	if not key then
		-- Unknown product: never mark it granted, or the player loses Robux.
		warn(`[Monetization] Receipt for unknown product {receipt.ProductId}. Is it in Config.Products?`)
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local ok, newlyGranted = PlayerDataService.grantPurchase(receipt.PlayerId, receipt.PurchaseId, key)
	if not ok then
		return Enum.ProductPurchaseDecision.NotProcessedYet -- Roblox will retry
	end

	local player = Players:GetPlayerByUserId(receipt.PlayerId)
	if player and newlyGranted then
		markGranted(player, key)
		tokenGrantedEvent:Fire(player, key)
	end
	return Enum.ProductPurchaseDecision.PurchaseGranted
end

----------------------------------------------------------------------------
-- Lifecycle
----------------------------------------------------------------------------
local function onPlayerAdded(player: Player)
	local id = Config.GamePasses.CustomCategory
	if id ~= 0 then
		local ok, owns = pcall(function()
			return MarketplaceService:UserOwnsGamePassAsync(player.UserId, id)
		end)
		if ok and player.Parent then
			ownsCustomCategory[player] = owns == true
		end
	end
	MonetizationService.pushWallet(player)
end

local function onPlayerRemoving(player: Player)
	ownsCustomCategory[player] = nil
	prompts[player] = nil
	local index = table.find(armedQueue, player)
	if index then
		table.remove(armedQueue, index)
	end
end

function MonetizationService.init()
	-- Only ONE script in the whole game may set ProcessReceipt.
	MarketplaceService.ProcessReceipt = processReceipt

	-- Fires when the dialog closes, purchased or not. Used ONLY to release
	-- deadline holds; granting is done by ProcessReceipt.
	MarketplaceService.PromptProductPurchaseFinished:Connect(function(userId: number, id: number, isPurchased: boolean)
		local player = Players:GetPlayerByUserId(userId)
		local prompt = player and prompts[player]
		if prompt and productId(prompt.key :: ProductKey) == id and prompt.closedAt == nil then
			prompt.closedAt = os.clock()
			prompt.purchased = isPurchased
		end
	end)

	MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(player: Player, passId: number, purchased: boolean)
		if purchased and passId == Config.GamePasses.CustomCategory then
			ownsCustomCategory[player] = true
			MonetizationService.pushWallet(player)
			passGrantedEvent:Fire(player)
		end
	end)

	-- Keep each client's wallet display current.
	PlayerDataService.Changed:Connect(function(player: Player)
		MonetizationService.pushWallet(player)
	end)

	Players.PlayerRemoving:Connect(onPlayerRemoving)
end

-- Called by GameManager once the player's data has loaded.
MonetizationService.onPlayerAdded = onPlayerAdded

return MonetizationService
