--!strict
-- MonetizationService: the game's only ProcessReceipt, receipt dedupe, the RequestPurchase gate with the
-- server-side prompt, entitlement attributes and the grant registry (T-056). Owned by systems-programmer.
-- Contract: docs/architecture.md 1b #2, section 2 #13, 3c, 4d, 4e, 4f. Pure rules: Util/PurchaseRules.
--
-- ProcessReceipt (3c) never loses a purchase and never grants twice:
--   1. Player not in this server or profile not loaded (waits up to RECEIPT_LOAD_WAIT_SEC) -> NotProcessedYet.
--   2. The same PurchaseId already running in this server -> NotProcessedYet (Roblox retries later).
--   3. PurchaseId already in `profile.receipts` -> confirm a save holds it, then PurchaseGranted (no new grant).
--   4. Unknown product id (ProductCatalog.byProductId nil, which includes every placeholder 0) or no grant fn
--      registered for its GrantKind -> NotProcessedYet, logged.
--   5. One DataService.update: the grant fn runs on a copy; on success the copy and the PurchaseId are merged into
--      the profile together (PurchaseRules.applyGrant). A refused, erroring or yielding grant changes nothing.
--   6. DataService.saveAndConfirm waits for a save that contains the PurchaseId. Only then PurchaseGranted.
--      Timeout or session end -> NotProcessedYet; the id stays in memory, so the retry goes to step 3, and if the
--      session ends unsaved both the grant and the id are lost together, so the retry grants once.
--   Any error anywhere -> NotProcessedYet. Every valid paid receipt is delivered, before FirstWin too (D-016 #9).
--   A restricted player's Robux-egg receipt is delivered as the fixed pet by PetService's RobuxEgg grant (4d).
--
-- RequestPurchase (2 #13) is a prompt gate only: rate limit (RateLimit.connect), string of <= 24 chars,
-- ProductCatalog.canSell, FirstWin, next ladder tier only, permanent items not owned, Starter Pack once, Robux eggs
-- need PaidRandomAllowed, pets need free inventory slots, Hype Snack refused past the 2 h cap (live seconds from
-- MultiplierService.getBoostSec, CR-G4), one open prompt at a time. Then the SERVER calls PromptProductPurchase.
-- There are no purchase touch pads (GDD 8b): nothing else in the game opens a prompt, and no Touched or ProximityPrompt handler reaches this file.
--
-- Grant registry (4e): Gameplay services call `registerGrant(kind, fn)` in their Start(). This service registers
-- Entitlement and Donation itself. Attributes PaidTier, Vip, AutoClickerOwned, StarterPackOwned are written here
-- on load and after every grant; `EntitlementsChanged` fires after every grant.
-- Logs never contain names, user ids or other personal info.

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local ComplianceService = require(script.Parent.ComplianceService)
local DataService = require(script.Parent.DataService)
local PurchaseRules = require(script.Parent.Util.PurchaseRules)
local TelemetryService = require(script.Parent.TelemetryService)

local EconomyConfig = require(ReplicatedStorage.Shared.Gameplay.EconomyConfig)
local ProductCatalog = require(ReplicatedStorage.Shared.Contracts.ProductCatalog)
local RateLimit = require(ReplicatedStorage.Shared.Contracts.RateLimit)
local Remotes = require(ReplicatedStorage.Shared.Contracts.Remotes)
local Types = require(ReplicatedStorage.Shared.Contracts.Types)

type ProfileData = Types.ProfileData
type GrantFn = PurchaseRules.GrantFn

local Attr = Types.PlayerAttr

local RECEIPT_LOAD_WAIT_SEC = 15
local SAVE_CONFIRM_SEC = 30
local PROMPT_OPEN_SEC = 60 -- a prompt with no PromptProductPurchaseFinished stops blocking new prompts after this

-- Player-facing text for refused prompts (server-built, never echoes client strings). nil = stay silent.
local REFUSAL_TEXT: { [string]: string } = {
	NoProductId = "This item isn't on sale yet.",
	NotOnSale = "This item isn't on sale.",
	FirstWin = "Win your first boss battle to open the shop!",
	Owned = "You already own this.",
	Restricted = "Robux eggs aren't available on your account.",
	InventoryFull = "Your pet inventory is full. Delete some pets first.",
	BoostCap = "Hype Snack is already near the 2 hour limit.",
	NotNextTier = "Only the next Mog Points tier can be bought.",
	PromptOpen = "Finish the open purchase first.",
}

local MonetizationService = {}

local grants: { [Types.GrantKind]: GrantFn } = {}
local inFlight: { [string]: boolean } = {} -- PurchaseIds being processed in this server
local promptOpenAt: { [Player]: number } = {}
local entitlementsChangedEvent: BindableEvent
local notifyRemote: RemoteEvent? = nil
local effectRemote: RemoteEvent? = nil

MonetizationService.EntitlementsChanged = (nil :: any) :: RBXScriptSignal -- (player: Player)

local function notify(player: Player, kind: Types.NotifyKind, text: string)
	local remote = notifyRemote
	if remote and player.Parent == Players then
		remote:FireClient(player, { kind = kind, text = text } :: Types.NotifyPayload)
	end
end

-- Attributes ------------------------------------------------------------------------------------------

local function writeAttributes(player: Player)
	local data = DataService.getData(player)
	if data == nil or player.Parent ~= Players then
		return
	end
	local ent = data.entitlements
	local tier = tonumber(ent.paidTier) or 0
	if tier ~= tier then
		tier = 0
	end
	player:SetAttribute(Attr.PaidTier, math.clamp(math.floor(tier), 0, ProductCatalog.LADDER_TIERS))
	player:SetAttribute(Attr.Vip, ent.vip == true)
	player:SetAttribute(Attr.AutoClickerOwned, ent.autoClicker == true)
	player:SetAttribute(Attr.StarterPackOwned, ent.starterPack == true)
end

-- ProcessReceipt -----------------------------------------------------------------------------------------

local function confirmSaved(player: Player, purchaseId: string): boolean
	return DataService.saveAndConfirm(player, function(saved)
		return PurchaseRules.savedHasReceipt(saved, purchaseId)
	end, SAVE_CONFIRM_SEC)
end

local function processReceiptInner(info: { [string]: any }): Enum.ProductPurchaseDecision
	local playerId, productId, rawPurchaseId = info.PlayerId, info.ProductId, info.PurchaseId
	if type(playerId) ~= "number" or type(productId) ~= "number" or rawPurchaseId == nil then
		warn("MonetizationService: malformed receipt")
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	local purchaseId = tostring(rawPurchaseId)

	local player = Players:GetPlayerByUserId(playerId)
	if player == nil then
		return Enum.ProductPurchaseDecision.NotProcessedYet -- Roblox retries when they next join
	end
	local data = DataService.waitForData(player, RECEIPT_LOAD_WAIT_SEC)
	if data == nil then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	-- Already granted earlier (this session or a previous one): never grant again, just make sure it is saved.
	if PurchaseRules.savedHasReceipt(data :: any, purchaseId) then
		return if confirmSaved(player, purchaseId)
			then Enum.ProductPurchaseDecision.PurchaseGranted
			else Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local entry = ProductCatalog.byProductId(productId)
	if entry == nil then
		warn(`MonetizationService: receipt for unknown product id {productId}; not processed`)
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	local grant = grants[entry.grantKind]
	if grant == nil then
		warn(
			`MonetizationService: no grant registered for {entry.grantKind} ({entry.key}); not processed yet`
		)
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local applied, reason = false, "NotRun"
	local tierBefore, tierAfter = 0, 0
	local updated = DataService.update(player, function(live)
		tierBefore = tonumber(live.entitlements.paidTier) or 0
		applied, reason = PurchaseRules.applyGrant(live, player, entry, purchaseId, grant)
		tierAfter = tonumber(live.entitlements.paidTier) or 0
	end)
	if reason == "Duplicate" then
		-- Raced with another grant of the same id between the check above and the update: already applied.
		return if confirmSaved(player, purchaseId)
			then Enum.ProductPurchaseDecision.PurchaseGranted
			else Enum.ProductPurchaseDecision.NotProcessedYet
	end
	if not updated or not applied then
		warn(`MonetizationService: grant for {entry.key} not applied ({reason}); not processed yet`)
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	writeAttributes(player)
	entitlementsChangedEvent:Fire(player)
	-- Section 5 (CR-G6): which special grant this was. Logged only after the save below holds it.
	local ladderFallback = entry.grantKind == "PaidTier" and not (tierAfter > tierBefore)
	local restrictedEgg = entry.grantKind == "RobuxEgg" and not ComplianceService.paidRandomAllowed(player)

	if not confirmSaved(player, purchaseId) then
		warn(
			`MonetizationService: save for {entry.key} not confirmed; not processed yet (retry will not regrant)`
		)
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	TelemetryService.custom(player, "Purchase", entry.priceRobux)
	if ladderFallback then
		TelemetryService.custom(player, "LadderFallback", entry.priceRobux) -- D-019 #3: granted as Hype Snack time
	end
	if restrictedEgg then
		TelemetryService.custom(player, "RestrictedEggGrant", entry.priceRobux) -- 4d: granted as the fixed pet
	end
	notify(player, "Success", `Thanks! {entry.displayName} is yours.`)
	local effect = effectRemote
	if effect then
		effect:FireClient(
			player,
			"Purchase",
			{ userId = player.UserId, productKey = entry.key } :: Types.EffectPayload
		)
	end
	return Enum.ProductPurchaseDecision.PurchaseGranted
end

local function processReceipt(info: { [string]: any }): Enum.ProductPurchaseDecision
	local purchaseId = if type(info) == "table" and info.PurchaseId ~= nil
		then tostring(info.PurchaseId)
		else nil
	if purchaseId == nil then
		warn("MonetizationService: receipt without PurchaseId")
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	if inFlight[purchaseId] then
		return Enum.ProductPurchaseDecision.NotProcessedYet -- the running call finishes it; Roblox retries
	end
	inFlight[purchaseId] = true
	local ok, result = pcall(processReceiptInner, info)
	inFlight[purchaseId] = nil
	if not ok then
		warn(`MonetizationService: ProcessReceipt error: {result}`)
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	return result
end

-- RequestPurchase ----------------------------------------------------------------------------------------

-- Live Hype Snack seconds left from MultiplierService.getBoostSec (architecture 1a, CR-G4). Call-time lookup of the
-- Gameplay module (never at file top, never in Init): the only Data -> Gameplay read. Read-only and yield-free.
-- nil when MultiplierService or getBoostSec is not there, or the call fails: PurchaseRules then uses the profile.
local function liveHypeSec(player: Player): number?
	local server = ServerScriptService:FindFirstChild("Server")
	local gameplay = server and server:FindFirstChild("Gameplay")
	local module = gameplay and gameplay:FindFirstChild("MultiplierService")
	if module == nil or not module:IsA("ModuleScript") then
		return nil
	end
	local ok, sec = pcall(function()
		local multiplier = (require :: any)(module)
		local getBoostSec = multiplier and multiplier.getBoostSec
		if type(getBoostSec) ~= "function" then
			return nil
		end
		return getBoostSec(player, "Hype")
	end)
	if not ok or type(sec) ~= "number" then
		return nil
	end
	return sec
end

local function onRequestPurchase(player: Player, key: any)
	if typeof(key) ~= "string" or #key > PurchaseRules.KEY_MAX_LEN then
		return
	end
	if player:GetAttribute(Attr.DataLoaded) ~= true then
		return
	end
	local data = DataService.getData(player)
	if data == nil or not DataService.isLoaded(player) then
		return
	end
	local openedAt = promptOpenAt[player]
	if openedAt and os.clock() - openedAt < PROMPT_OPEN_SEC then
		notify(player, "Info", REFUSAL_TEXT.PromptOpen)
		return
	end

	local ok, reason = PurchaseRules.canPrompt(data, key, {
		firstWin = data.firstWin == true or player:GetAttribute(Attr.FirstWin) == true,
		paidRandomAllowed = ComplianceService.paidRandomAllowed(player),
		inventoryCap = EconomyConfig.INVENTORY_CAP,
		boostCapSec = EconomyConfig.BOOST_CAP_SEC,
		hypeSecLeft = liveHypeSec(player),
	})
	if not ok then
		local text = REFUSAL_TEXT[reason or ""]
		if text then
			notify(player, "Info", text)
		end
		return
	end

	local entry = ProductCatalog.get(key)
	if entry == nil then
		return
	end
	promptOpenAt[player] = os.clock()
	local called, err = pcall(function()
		MarketplaceService:PromptProductPurchase(player, entry.productId)
	end)
	if not called then
		promptOpenAt[player] = nil
		warn(`MonetizationService: PromptProductPurchase failed for {entry.key}: {err}`)
	end
end

-- Public API (architecture 1b) ------------------------------------------------------------------------

-- Gameplay services call this in Start(). `fn` mutates the `data` table it is handed, synchronously (no yields,
-- no DataService calls); it returns false if it cannot grant now (the receipt is retried later).
function MonetizationService.registerGrant(kind: Types.GrantKind, fn: GrantFn)
	assert(type(fn) == "function", "MonetizationService.registerGrant: fn must be a function")
	if grants[kind] ~= nil then
		warn(`MonetizationService: grant for {kind} registered twice; keeping the newest`)
	end
	grants[kind] = fn
end

function MonetizationService.getPaidTier(player: Player): number
	local data = DataService.getData(player)
	local tier = if data then tonumber(data.entitlements.paidTier) else nil
	if tier == nil or tier ~= tier then
		return 0
	end
	return math.clamp(math.floor(tier), 0, ProductCatalog.LADDER_TIERS)
end

function MonetizationService.hasVip(player: Player): boolean
	local data = DataService.getData(player)
	return data ~= nil and data.entitlements.vip == true
end

-- Permanent or once-only entitlements only (repeatable products are never "owned").
function MonetizationService.owns(player: Player, key: Types.ProductKey): boolean
	local data = DataService.getData(player)
	return data ~= nil and PurchaseRules.owns(data, key)
end

-- Lifecycle ------------------------------------------------------------------------------------------

function MonetizationService:Init()
	entitlementsChangedEvent = Instance.new("BindableEvent")
	MonetizationService.EntitlementsChanged = entitlementsChangedEvent.Event
	grants.Entitlement = PurchaseRules.entitlementGrant
	grants.Donation = PurchaseRules.donationGrant
end

function MonetizationService:Start()
	local missing = ProductCatalog.missingIds()
	if #missing > 0 then
		warn(
			`MonetizationService: {#missing} on-sale products still use placeholder id 0 (expected until the owner `
				.. `creates them): {table.concat(missing, ", ")}`
		)
	end

	notifyRemote = Remotes.getEvent("Notify")
	effectRemote = Remotes.getEvent("PlayEffect")
	MarketplaceService.ProcessReceipt = processReceipt
	RateLimit.connect("RequestPurchase", onRequestPurchase)
	MarketplaceService.PromptProductPurchaseFinished:Connect(function(userId: number)
		local player = Players:GetPlayerByUserId(userId)
		if player then
			promptOpenAt[player] = nil
		end
	end)

	DataService.ProfileLoaded:Connect(function(player: Player)
		writeAttributes(player)
		entitlementsChangedEvent:Fire(player) -- re-apply permanent items on join (GDD 8d)
	end)
	Players.PlayerRemoving:Connect(function(player: Player)
		promptOpenAt[player] = nil
	end)
	for _, player in Players:GetPlayers() do
		if DataService.isLoaded(player) then
			task.spawn(writeAttributes, player)
		end
	end
end

return MonetizationService
