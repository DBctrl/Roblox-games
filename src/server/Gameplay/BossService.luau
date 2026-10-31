--!strict
-- BossService (architecture 1b #13, layer L1). Owned by gameplay-programmer.
-- `RequestBossFight(bossId)`: the server checks the id, world, distance, MP threshold and Activity, runs a 3 s
-- pose-off, re-checks the player before paying, then rests 1 s (4 s cycle, GDD 4.4). MP is a threshold, never
-- spent. Coins = BossCoins x MultiplierService.getCoinMultiplier (coinRebirthMult x free Coin Snack); pets and
-- paid tiers never touch coins (GDD 4.1, 8g). Sole writer of `FirstWin` and `BestCoinsPerSec`.
-- No loops: each fight is two task.delay calls, so 12 players fighting at once costs nothing per frame.
-- If ZoneService is missing, fights are refused (fail closed).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ActivityService = require(script.Parent.ActivityService)
local Deps = require(script.Parent.Util.Deps)
local EconomyConfig = require(ReplicatedStorage.Shared.Gameplay.EconomyConfig)
local Guard = require(script.Parent.Util.Guard)
local MultiplierService = require(script.Parent.MultiplierService)
local NumberFormat = require(ReplicatedStorage.Shared.Contracts.NumberFormat)
local RateLimit = require(ReplicatedStorage.Shared.Contracts.RateLimit)
local Remotes = require(ReplicatedStorage.Shared.Contracts.Remotes)
local Types = require(ReplicatedStorage.Shared.Contracts.Types)

local Attr = Types.PlayerAttr
type Boss = EconomyConfig.Boss

local BOSS_ID_MAX_LEN = 32 -- architecture section 2 #2
local EFFECT_PER_SEC = 10 -- architecture section 2 #18: PlayEffect <= 10/s per server

local bossWonEvent = Instance.new("BindableEvent")

local BossService = {}
BossService.BossWon = bossWonEvent.Event -- (player: Player, bossId: string, coins: number, auto: boolean)

local notifyRemote: RemoteEvent? = nil
local effectRemote: RemoteEvent? = nil
local effectBucket = RateLimit.newBucket(EFFECT_PER_SEC, os.clock())

local function unlockedWorld(data: Types.ProfileData, world: number): boolean
	return world == 1 or (world == 2 and data.world2Unlocked == true)
end

local function currentMp(data: Types.ProfileData): number
	return Guard.clampFinite(data.mp, 0, math.huge, 0)
end

-- Strongest boss in the player's current world with MP >= need (used by Auto-Mog, sprint 2).
function BossService.bestBeatable(player: Player): string?
	local zone = Deps.zone()
	local data = Deps.data().getData(player)
	if zone == nil or data == nil then
		return nil
	end
	local world = zone.getWorld(player)
	local mp = currentMp(data)
	for i = #EconomyConfig.BOSSES, 1, -1 do
		local boss = EconomyConfig.BOSSES[i]
		if boss.world == world and mp >= boss.mpNeed then
			return boss.id
		end
	end
	return nil
end

-- Coins/s of the strongest boss the player can beat now in any unlocked world, without Coin Snack.
-- Never below Sleepy Sid's rate, so daily/duel rewards for a brand-new player are not 0.
function BossService.bestCoinsPerSec(player: Player): number
	local data = Deps.data().getData(player)
	local first = EconomyConfig.BOSSES[1]
	if data == nil then
		return EconomyConfig.bossCoinsPerSec(first, 0)
	end
	local mp = currentMp(data)
	local best = first
	for _, boss in EconomyConfig.BOSSES do
		if unlockedWorld(data, boss.world) and mp >= boss.mpNeed and boss.coins > best.coins then
			best = boss
		end
	end
	return EconomyConfig.bossCoinsPerSec(best, data.rebirths)
end

local function refreshAttributes(player: Player)
	local data = Deps.data().getData(player)
	if data == nil then
		return
	end
	player:SetAttribute(Attr.FirstWin, data.firstWin == true)
	player:SetAttribute(Attr.BestCoinsPerSec, BossService.bestCoinsPerSec(player))
end

local function playWinEffect(player: Player, boss: Boss, coins: number)
	local zone = Deps.zone()
	if effectRemote == nil or zone == nil then
		return
	end
	if not RateLimit.take(effectBucket, EFFECT_PER_SEC, EFFECT_PER_SEC, os.clock()) then
		return -- cosmetic only; skipped when the server is busy
	end
	local payload: Types.EffectPayload = { userId = player.UserId, bossId = boss.id, amount = coins }
	for _, other in Players:GetPlayers() do
		if zone.getWorld(other) == boss.world then
			effectRemote:FireClient(other, "BossWin" :: Types.EffectId, payload)
		end
	end
end

-- Runs after the 3 s pose-off. Re-checks that the player is still here, in the boss's world, and above the
-- threshold, then pays. The activity is always released 1 s later (or at once if the fight is void).
local function award(player: Player, boss: Boss, auto: boolean)
	local dataApi = Deps.data()
	local zone = Deps.zone()
	local data = dataApi.getData(player)
	local valid = player.Parent == Players
		and data ~= nil
		and zone ~= nil
		and ActivityService.get(player) == "BossFight"
		and zone.getWorld(player) == boss.world
		and currentMp(data) >= boss.mpNeed
	if not valid or data == nil then
		ActivityService.finish(player, "BossFight")
		return
	end

	local coins = math.floor(boss.coins * MultiplierService.getCoinMultiplier(player))
	-- addCoins returns the new BALANCE (or 0 on failure), so report the amount won, not the balance (QA-8).
	local added = if dataApi.addCoins(player, coins, "BossWin") > 0 then coins else 0
	local firstWinNow = false
	dataApi.update(player, function(d)
		d.stats.bossWins += 1
		if not d.firstWin then
			d.firstWin = true
			firstWinNow = true
		end
	end)
	refreshAttributes(player)

	bossWonEvent:Fire(player, boss.id, added, auto)
	playWinEffect(player, boss, added)
	if added > 0 then
		Deps.economy(player, "Source", added, "BossWin")
	end
	if firstWinNow then
		Deps.funnel(player, "FirstWin")
	end
	task.delay(EconomyConfig.BOSS_COOLDOWN_SEC, ActivityService.finish, player, "BossFight")
end

-- Starts a fight. `auto == true` = Auto-Mog (IdleService): skips the distance check, everything else applies.
function BossService.tryFight(player: Player, bossId: string, auto: boolean): (boolean, string?)
	local dataApi = Deps.data()
	local data = dataApi.getData(player)
	if data == nil then
		return false, "NotLoaded"
	end
	if not Guard.isShortString(bossId, BOSS_ID_MAX_LEN) then
		return false, "BadArgs"
	end
	local boss = EconomyConfig.BOSS_BY_ID[bossId]
	if boss == nil then
		return false, "UnknownBoss"
	end
	local zone = Deps.zone()
	if zone == nil then
		return false, "NoZone"
	end
	if zone.getWorld(player) ~= boss.world then
		return false, "WrongWorld"
	end
	if auto ~= true and not zone.isNearBoss(player, bossId) then -- QA-4: only a real `true` skips range
		return false, "TooFar"
	end
	if currentMp(data) < boss.mpNeed then
		return false, "NeedMp"
	end
	if not ActivityService.tryBegin(player, "BossFight") then
		return false, "Busy"
	end
	task.delay(EconomyConfig.BOSS_FIGHT_SEC, award, player, boss, auto == true)
	return true
end

function BossService.Init()
	EconomyConfig.validate() -- pure; a bad table stops the server at boot, not mid-game
end

function BossService.Start()
	notifyRemote = Remotes.getEvent("Notify")
	effectRemote = Remotes.getEvent("PlayEffect")
	local dataApi = Deps.data()

	RateLimit.connect("RequestBossFight", function(player: Player, bossId: any)
		if not dataApi.isLoaded(player) or not Guard.isShortString(bossId, BOSS_ID_MAX_LEN) then
			return
		end
		local ok, reason = BossService.tryFight(player, bossId, false)
		if ok or notifyRemote == nil then
			return
		end
		local boss = EconomyConfig.BOSS_BY_ID[bossId]
		local text: string? = nil
		if reason == "TooFar" then
			text = "Walk closer to the boss!"
		elseif reason == "NeedMp" and boss then
			text = `Need {NumberFormat.abbreviate(boss.mpNeed)} MP`
		end
		if text then
			local payload: Types.NotifyPayload = { kind = "Error", text = text }
			notifyRemote:FireClient(player, payload)
		end
	end)

	dataApi.ProfileLoaded:Connect(refreshAttributes)
	for _, player in Players:GetPlayers() do
		if dataApi.isLoaded(player) then
			refreshAttributes(player)
		end
	end
end

return BossService
