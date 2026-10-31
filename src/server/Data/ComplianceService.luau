--!strict
-- ComplianceService: PolicyService gate for paid random items (Robux eggs). Owned by systems-programmer.
-- Contract: docs/architecture.md section 4d; lawyer ruling legal.md 2.3/2.4 (D-016 #2).
--
-- * Runs on the SERVER for every player at join: `PolicyService:GetPolicyInfoForPlayerAsync` inside `pcall`,
--   first try plus up to 3 retries after 2, 4 and 8 s. Result cached per player for the session.
-- * FAIL CLOSED: `PaidRandomAllowed` is false from the moment the player joins and stays false unless a call
--   succeeds and `ArePaidRandomItemsRestricted` is exactly `false`. Any error, missing or non-boolean field means
--   restricted. No countries are hard-coded anywhere.
-- * The attribute is read-only UI info (EggController hides Robux eggs). The real gate is
--   `ComplianceService.paidRandomAllowed(player)`, which MonetizationService's RequestPurchase calls (T-056).

local Players = game:GetService("Players")
local PolicyService = game:GetService("PolicyService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Types = require(ReplicatedStorage.Shared.Contracts.Types)

local ATTR = Types.PlayerAttr.PaidRandomAllowed
local RETRY_DELAYS_SEC = { 2, 4, 8 }

local ComplianceService = {}

-- true = allowed, false = restricted or unknown. Missing entry = not checked yet (also treated as false).
local allowed: { [Player]: boolean } = {}
local checking: { [Player]: boolean } = {}

-- Pure: maps a pcall result to the allow flag. Exposed for qa unit tests.
function ComplianceService.evaluate(ok: boolean, info: any): boolean?
	if not ok or type(info) ~= "table" then
		return nil -- call failed: retry, then fail closed
	end
	local restricted = info.ArePaidRandomItemsRestricted
	if type(restricted) ~= "boolean" then
		return false -- answered without the key: treat as restricted, no retry
	end
	return not restricted
end

local function check(player: Player)
	if checking[player] or allowed[player] ~= nil then
		return
	end
	checking[player] = true
	local result: boolean? = nil
	for attempt = 1, #RETRY_DELAYS_SEC + 1 do
		if player.Parent ~= Players then
			break
		end
		local ok, info = pcall(PolicyService.GetPolicyInfoForPlayerAsync, PolicyService, player)
		result = ComplianceService.evaluate(ok, info)
		if result ~= nil then
			break
		end
		if attempt <= #RETRY_DELAYS_SEC then
			task.wait(RETRY_DELAYS_SEC[attempt])
		end
	end
	checking[player] = nil
	if player.Parent ~= Players then
		return
	end
	if result == nil then
		warn("ComplianceService: policy check failed after retries; treating player as restricted")
	end
	local value = result == true
	allowed[player] = value
	player:SetAttribute(ATTR, value)
end

local function onPlayerAdded(player: Player)
	if allowed[player] == nil then
		player:SetAttribute(ATTR, false) -- fail closed until checked
	end
	task.spawn(check, player)
end

-- False until a successful check said paid random items are allowed (fail closed).
function ComplianceService.paidRandomAllowed(player: Player): boolean
	return allowed[player] == true
end

function ComplianceService:Init() end

function ComplianceService:Start()
	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(function(player: Player)
		allowed[player] = nil
		checking[player] = nil
	end)
	for _, player in Players:GetPlayers() do
		onPlayerAdded(player)
	end
end

return ComplianceService
