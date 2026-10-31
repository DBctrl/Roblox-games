--!strict
-- EffectsController (architecture 1d #34). Owned by physics-programmer. Client-only and cosmetic.
-- Runs effects from exactly two sources: the server's `PlayEffect` remote and the local player's own taps.
-- It never sends a remote, never reads or writes game state and never decides anything; TapController (UI)
-- still owns sending `TapBatch`. All effect instances are pooled (Util/EffectPool) and built in Init.
-- Network ownership: none involved. Pool parts are client-created, anchored, non-colliding and never replicate.
-- Boss pose-off/ragdoll is T-022; rank-up/rebirth cinematics belong to CinematicController.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local EffectPool = require(script.Parent.Util.EffectPool)
local EffectsConfig = require(ReplicatedStorage.Shared.Physics.EffectsConfig)
local Remotes = require(ReplicatedStorage.Shared.Contracts.Remotes)
local Types = require(ReplicatedStorage.Shared.Contracts.Types)

local EffectsController = {}

local localPlayer = Players.LocalPlayer
local folder: Folder
local tapPool: EffectPool.Pool
local coinPool: EffectPool.Pool
local celebratePool: EffectPool.Pool
local rayParams: RaycastParams
local tapTimes: { number } = {} -- ring of recent tap times for the local per-second cap
local tapIndex = 0

local function rootOf(player: Player?): BasePart?
	local character = player and player.Character
	if not character then
		return nil
	end
	local root = character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return root
	end
	return nil
end

-- Position above the character of `userId` (nil if not in this server or not streamed in).
local function spotAbove(userId: unknown, height: number): Vector3?
	if type(userId) ~= "number" then
		return nil
	end
	local root = rootOf(Players:GetPlayerByUserId(userId))
	return if root then root.Position + Vector3.new(0, height, 0) else nil
end

local function inRange(position: Vector3): boolean
	local camera = Workspace.CurrentCamera
	if not camera then
		return false
	end
	return (camera.CFrame.Position - position).Magnitude <= EffectsConfig.MAX_EFFECT_DISTANCE
end

local function burst(pool: EffectPool.Pool, position: Vector3?, count: number)
	if position and inRange(position) then
		EffectPool.emit(pool, position, count)
	end
end

-- PlayEffect handlers. Payload fields are checked for type here; bad payloads just play nothing.
type Handler = (payload: { [string]: unknown }) -> ()

local handlers: { [Types.EffectId]: Handler } = {
	BossWin = function(p)
		local amount = if type(p.amount) == "number" then p.amount else nil
		local spot = spotAbove(p.userId, EffectsConfig.CoinBurst.heightOffset)
		burst(coinPool, spot, EffectsConfig.coinParticles(amount))
	end,
	DailyReward = function(p)
		local amount = if type(p.amount) == "number" then p.amount else nil
		local spot = spotAbove(localPlayer.UserId, EffectsConfig.CoinBurst.heightOffset)
		burst(coinPool, spot, EffectsConfig.coinParticles(amount))
	end,
	Donation = function(p)
		-- userId is omitted when the donor opted out of the board: no positional effect then.
		local tier = if type(p.tier) == "number" then p.tier else nil
		local spot = spotAbove(p.userId, EffectsConfig.CoinBurst.heightOffset)
		burst(coinPool, spot, EffectsConfig.donationParticles(tier))
	end,
	RankUp = function(p)
		burst(
			celebratePool,
			spotAbove(p.userId, EffectsConfig.Celebrate.heightOffset),
			EffectsConfig.Celebrate.RankUp
		)
	end,
	Rebirth = function(p)
		local spot = spotAbove(p.userId, EffectsConfig.Celebrate.heightOffset)
		burst(celebratePool, spot, EffectsConfig.Celebrate.Rebirth)
	end,
	Purchase = function(p)
		local spot = spotAbove(p.userId, EffectsConfig.Celebrate.heightOffset)
		burst(celebratePool, spot, EffectsConfig.Celebrate.Purchase)
	end,
	-- DuelKnockback / DuelBounce: handled by RagdollController (later ticket); nothing here.
}

local function onPlayEffect(effect: unknown, payload: unknown)
	if type(effect) ~= "string" then
		return
	end
	local handler = handlers[effect :: Types.EffectId]
	if not handler then
		return
	end
	handler(if type(payload) == "table" then payload :: { [string]: unknown } else {})
end

-- Local cap: at most Tap.maxPerSecond sparkles in any rolling second (same cap as TapController).
local function tapAllowed(now: number): boolean
	local cap = EffectsConfig.Tap.maxPerSecond
	local slot = tapIndex % cap + 1
	local oldest = tapTimes[slot]
	if oldest and now - oldest < 1 then
		return false
	end
	tapIndex = slot
	tapTimes[slot] = now
	return true
end

local function tapSpot(screenPosition: Vector3): Vector3?
	local camera = Workspace.CurrentCamera
	if camera then
		local ray = camera:ScreenPointToRay(screenPosition.X, screenPosition.Y, 0)
		local hit = Workspace:Raycast(ray.Origin, ray.Direction * EffectsConfig.Tap.rayLength, rayParams)
		if hit then
			return hit.Position
		end
	end
	local root = rootOf(localPlayer)
	return if root then root.Position + Vector3.new(0, EffectsConfig.Tap.characterOffsetY, 0) else nil
end

local function onInputBegan(input: InputObject, gameProcessed: boolean)
	if gameProcessed then
		return -- over GUI or consumed by a control, same rule as TapController
	end
	local kind = input.UserInputType
	if kind ~= Enum.UserInputType.MouseButton1 and kind ~= Enum.UserInputType.Touch then
		return
	end
	if localPlayer:GetAttribute(Types.PlayerAttr.DataLoaded) ~= true then
		return
	end
	if not tapAllowed(os.clock()) then
		return
	end
	local spot = tapSpot(input.Position)
	if spot then
		EffectPool.emit(tapPool, spot, EffectsConfig.Tap.particlesPerTap)
	end
end

function EffectsController:Init()
	folder = Instance.new("Folder")
	folder.Name = "ClientEffects"
	local pools = EffectsConfig.Pools
	tapPool = EffectPool.new("TapSparkle", pools.TapSparkle.size, pools.TapSparkle.look, folder)
	coinPool = EffectPool.new("CoinBurst", pools.CoinBurst.size, pools.CoinBurst.look, folder)
	celebratePool = EffectPool.new("Celebrate", pools.Celebrate.size, pools.Celebrate.look, folder)
	folder.Parent = Workspace

	rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	rayParams.FilterDescendantsInstances = { folder }
end

function EffectsController:Start()
	-- Remotes.getEvent yields (WaitForChild), so it runs here, never in Init.
	Remotes.getEvent("PlayEffect").OnClientEvent:Connect(onPlayEffect)
	UserInputService.InputBegan:Connect(onInputBegan)
end

return EffectsController
