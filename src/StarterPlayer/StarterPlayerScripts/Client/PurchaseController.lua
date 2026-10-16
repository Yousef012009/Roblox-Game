--!strict
--[[
	PurchaseController  (ModuleScript)  ·  StarterPlayerScripts/Client/PurchaseController

	Client side of monetization. It never grants anything: every button
	fires Remotes.RequestPurchase, and the server decides whether to spend a
	saved token or open the Robux prompt.

	  • Lobby dock (lobby + spectators): status line + "📣 CALL NEXT CASE"
	    (Force Caller), shown as R$ price, owned count or ARMED ✓
	  • Bribe modal: "💰 BRIBE THE DETECTIVE?" with a 5-second fuse after
	    you hesitate or repeat
	  • Price lookups (GetProductInfo) and the labels the other controllers
	    use: "×2" when you own tokens, "R$25" when you don't
]]

local MarketplaceService = game:GetService("MarketplaceService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local UIKit = require(script.Parent.UIKit)

local C = UIKit.Colors
local F = UIKit.Fonts

type TokenKey = "SkipTurn" | "Revive" | "ForceCaller"

local PurchaseController = {}
PurchaseController.__index = PurchaseController

export type PurchaseController = typeof(setmetatable(
	{} :: {
		wallet: Remotes.Wallet?,
		_prices: { [string]: number },
		_lobbyDock: Frame,
		_lobbyStatus: TextLabel,
		_forceButton: TextButton,
		_bribeOverlay: Frame,
		_bribeReason: TextLabel,
		_bribeFill: Frame,
		_bribeCount: TextLabel,
		_bribePay: TextButton,
		_bribe: Remotes.BribeOffer?,
		_bribeStartedAt: number,
		_onWalletChanged: { () -> () },
	},
	PurchaseController
))

function PurchaseController.new(screen: ScreenGui): PurchaseController
	local self = setmetatable({}, PurchaseController) :: any
	self._prices = {}
	self._onWalletChanged = {}
	self._bribeStartedAt = 0

	------------------------------------------------------------------ lobby dock
	self._lobbyDock = UIKit.panel({
		Name = "LobbyDock",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -14),
		Size = UDim2.new(0.6, 0, 0, 56),
		Parent = screen,
	}, 16)
	UIKit.sizeLimit(Vector2.new(290, 50), Vector2.new(560, 60)).Parent = self._lobbyDock
	self._lobbyStatus = UIKit.label({
		Name = "Status",
		Position = UDim2.fromOffset(14, 0),
		Size = UDim2.new(1, -200, 1, 0),
		Font = F.Display,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = "WAITING FOR SUSPECTS…",
		Parent = self._lobbyDock,
	}, 22)
	self._forceButton = UIKit.button({
		Name = "ForceCaller",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -7, 0.5, 0),
		Size = UDim2.new(0, 178, 1, -14),
		Text = "📣 CALL NEXT CASE",
		Visible = false,
		Parent = self._lobbyDock,
	})
	self._forceButton.Activated:Connect(function()
		Remotes.RequestPurchase:FireServer("ForceCaller")
	end)

	------------------------------------------------------------------ bribe modal
	self._bribeOverlay = UIKit.create("Frame", {
		Name = "Bribe",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Color3.fromRGB(40, 0, 0),
		BackgroundTransparency = 0.5,
		Visible = false,
		ZIndex = 20,
		Parent = screen,
	})
	local card = UIKit.panel({
		Name = "Card",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.55),
		Size = UDim2.fromScale(0.86, 0.5),
		Parent = self._bribeOverlay,
	}, 18)
	UIKit.sizeLimit(Vector2.new(280, 220), Vector2.new(460, 260)).Parent = card
	UIKit.padding(16, 14).Parent = card
	UIKit.stroke(C.Amber, 2).Parent = card

	UIKit.label({
		Name = "Title",
		Size = UDim2.new(1, -50, 0, 34),
		Font = F.Title,
		TextColor3 = C.Amber,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = "💰 BRIBE THE DETECTIVE?",
		Parent = card,
	}, 30)
	self._bribeCount = UIKit.label({
		Name = "Count",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(1, 0),
		Size = UDim2.fromOffset(44, 34),
		Font = F.Display,
		TextColor3 = C.Red,
		TextXAlignment = Enum.TextXAlignment.Right,
		Parent = card,
	}, 32)
	self._bribeReason = UIKit.label({
		Name = "Reason",
		Position = UDim2.fromOffset(0, 40),
		Size = UDim2.new(1, 0, 0, 40),
		TextColor3 = C.Paper,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = card,
	}, 20)

	local fuse = UIKit.create("Frame", {
		Name = "Fuse",
		Position = UDim2.fromOffset(0, 88),
		Size = UDim2.new(1, 0, 0, 8),
		BackgroundColor3 = C.InkSoft,
		Parent = card,
	}, { UIKit.round() })
	self._bribeFill = UIKit.create("Frame", {
		Name = "Fill",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = C.Red,
		Parent = fuse,
	}, { UIKit.round() })

	self._bribePay = UIKit.button({
		Name = "Pay",
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.fromScale(0, 1),
		Size = UDim2.new(0.62, -6, 0, 54),
		Text = "PAY",
		Parent = card,
	}, C.Robux, C.Paper)
	local decline = UIKit.button({
		Name = "Decline",
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.fromScale(1, 1),
		Size = UDim2.new(0.38, -6, 0, 54),
		Text = "ACCEPT FATE",
		Parent = card,
	}, C.InkSoft, C.Muted)

	self._bribePay.Activated:Connect(function()
		if self._bribe then
			Remotes.RequestPurchase:FireServer("Revive")
		end
	end)
	decline.Activated:Connect(function()
		if self._bribe then
			Remotes.DeclineBribe:FireServer()
			self:hideBribe()
		end
	end)

	self:_loadPrices()
	return self
end

----------------------------------------------------------------------------
-- Prices & labels
----------------------------------------------------------------------------
function PurchaseController._loadPrices(self: PurchaseController)
	for key, id in Config.Products :: { [string]: number } do
		if id ~= 0 then
			task.spawn(function()
				local ok, info = pcall(function()
					return MarketplaceService:GetProductInfo(id, Enum.InfoType.Product)
				end)
				if ok and info and info.PriceInRobux then
					self._prices[key] = info.PriceInRobux
					self:_notify()
				end
			end)
		end
	end
	local passId = Config.GamePasses.CustomCategory
	if passId ~= 0 then
		task.spawn(function()
			local ok, info = pcall(function()
				return MarketplaceService:GetProductInfo(passId, Enum.InfoType.GamePass)
			end)
			if ok and info and info.PriceInRobux then
				self._prices.CustomCategory = info.PriceInRobux
				self:_notify()
			end
		end)
	end
end

function PurchaseController._notify(self: PurchaseController)
	for _, callback in self._onWalletChanged do
		task.spawn(callback)
	end
end

-- Run `callback` whenever the wallet or a price changes.
function PurchaseController.onChanged(self: PurchaseController, callback: () -> ())
	table.insert(self._onWalletChanged, callback)
end

function PurchaseController.priceLabel(self: PurchaseController, key: string): string
	local price = self._prices[key]
	return if price then `R${price}` else "BUY" -- price still loading (or simulated in Studio)
end

-- "×2" if tokens are owned, "R$25" otherwise, nil if the product is off.
function PurchaseController.labelFor(self: PurchaseController, key: TokenKey): string?
	local wallet = self.wallet
	if not wallet or not wallet.Enabled[key] then
		return nil
	end
	local owned = wallet.Tokens[key] or 0
	if owned > 0 then
		return `×{owned}`
	end
	return self:priceLabel(key)
end

function PurchaseController.setWallet(self: PurchaseController, wallet: Remotes.Wallet)
	self.wallet = wallet

	local label = self:labelFor("ForceCaller")
	self._forceButton.Visible = label ~= nil
	if wallet.ForceCallerArmed then
		self._forceButton.Text = "📣 ARMED ✓"
		self._forceButton.BackgroundColor3 = C.Green
	elseif label then
		self._forceButton.Text = `📣 CALL NEXT · {label}`
		self._forceButton.BackgroundColor3 = C.Amber
	end

	if self._bribe then
		self:_refreshBribeButton()
	end
	self:_notify()
end

----------------------------------------------------------------------------
-- Lobby dock
----------------------------------------------------------------------------
function PurchaseController.setLobbyVisible(self: PurchaseController, visible: boolean)
	self._lobbyDock.Visible = visible
end

function PurchaseController.setLobbyStatus(self: PurchaseController, text: string)
	self._lobbyStatus.Text = text
end

----------------------------------------------------------------------------
-- Bribe modal
----------------------------------------------------------------------------
function PurchaseController._refreshBribeButton(self: PurchaseController)
	local wallet = self.wallet
	local owned = if wallet then wallet.Tokens.Revive else 0
	self._bribePay.Text = if owned > 0 then `USE BRIBE ×{owned}` else `PAY {self:priceLabel("Revive")}`
end

function PurchaseController.showBribe(self: PurchaseController, offer: Remotes.BribeOffer, serverNow: number)
	self._bribe = offer
	self._bribeStartedAt = serverNow
	self._bribeReason.Text = if offer.reason == "Repeat"
		then "You repeated a word! Slip the detective some Robux and stay in the round."
		else "You hesitated! Slip the detective some Robux and stay in the round."
	self:_refreshBribeButton()
	self._bribeOverlay.Visible = true
end

function PurchaseController.hideBribe(self: PurchaseController)
	self._bribe = nil
	self._bribeOverlay.Visible = false
end

function PurchaseController.update(self: PurchaseController, serverNow: number)
	local offer = self._bribe
	if not offer then
		return
	end
	local total = math.max(offer.endsAt - self._bribeStartedAt, 0.001)
	local remaining = math.max(offer.endsAt - serverNow, 0)
	self._bribeFill.Size = UDim2.fromScale(remaining / total, 1)
	self._bribeCount.Text = tostring(math.ceil(remaining))
end

return PurchaseController
