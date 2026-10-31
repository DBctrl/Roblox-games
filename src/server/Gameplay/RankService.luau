--!strict
-- RankService (architecture 1b #10, layer L1). Owned by gameplay-programmer.
-- Rank comes from lifetime MP against EconomyConfig.RANKS (GDD 7) and never goes down. TapService calls
-- `onLifetimeMp` after every MP gain; a cached next threshold keeps that call cheap. On a rank-up: profile rank,
-- `Rank` and `LookId` attributes (sole writer), `RankUp` signal, the new look, `PlayEffect RankUp` and a
-- server banner (at most BANNER_PER_SEC per server, extras skipped).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Deps = require(script.Parent.Util.Deps)
local EconomyConfig = require(ReplicatedStorage.Shared.Gameplay.EconomyConfig)
local Guard = require(script.Parent.Util.Guard)
local RateLimit = require(ReplicatedStorage.Shared.Contracts.RateLimit)
local Remotes = require(ReplicatedStorage.Shared.Contracts.Remotes)
local Types = require(ReplicatedStorage.Shared.Contracts.Types)

local Attr = Types.PlayerAttr

local BANNER_PER_SEC = 1 -- architecture section 2 #17: banners FireAllClients <= 1/s per server
local EFFECT_PER_SEC = 10 -- architecture section 2 #18: PlayEffect <= 10/s per server

local rankUpEvent = Instance.new("BindableEvent")

local RankService = {}
RankService.RankUp = rankUpEvent.Event -- (player: Player, rank: number)

local ranks: { [Player]: number } = {}
local nextNeed: { [Player]: number } = {} -- lifetime MP of the next rank (math.huge at max rank)
local bannerBucket = RateLimit.newBucket(BANNER_PER_SEC, os.clock())
local effectBucket = RateLimit.newBucket(EFFECT_PER_SEC, os.clock())
local notifyRemote: RemoteEvent? = nil
local effectRemote: RemoteEvent? = nil

local function setLook(player: Player, rank: number)
	local character = Deps.character()
	local fn = character and character.setLook -- nil until CharacterService gains setLook (sprint 2)
	if fn then
		fn(player, EconomyConfig.RANKS[rank].lookId)
	end
end

local function apply(player: Player, rank: number)
	ranks[player] = rank
	local nextRow = EconomyConfig.RANKS[rank + 1]
	nextNeed[player] = if nextRow then nextRow.lifetimeMp else math.huge
	player:SetAttribute(Attr.Rank, rank)
	player:SetAttribute(Attr.LookId, EconomyConfig.RANKS[rank].lookId)
	setLook(player, rank)
end

local function announce(player: Player, rank: number)
	rankUpEvent:Fire(player, rank)
	Deps.funnel(player, "FirstRankUp")
	if effectRemote and RateLimit.take(effectBucket, EFFECT_PER_SEC, EFFECT_PER_SEC, os.clock()) then
		local payload: Types.EffectPayload = { userId = player.UserId, rank = rank }
		effectRemote:FireAllClients("RankUp" :: Types.EffectId, payload)
	end
	if notifyRemote and RateLimit.take(bannerBucket, BANNER_PER_SEC, BANNER_PER_SEC, os.clock()) then
		local payload: Types.NotifyPayload = {
			kind = "Banner",
			text = `{player.DisplayName} leveled up to {EconomyConfig.RANKS[rank].name}!`,
		}
		notifyRemote:FireAllClients(payload)
	end
end

-- Called by TapService after each MP gain with the new lifetime total.
function RankService.onLifetimeMp(player: Player, lifetimeMp: number)
	local current = ranks[player]
	local need = nextNeed[player]
	if current == nil or need == nil or not Guard.isFinite(lifetimeMp) or lifetimeMp < need then
		return
	end
	local newRank = EconomyConfig.rankForLifetimeMp(lifetimeMp)
	if newRank <= current then
		return
	end
	local ok = Deps.data().update(player, function(data)
		data.rank = math.max(data.rank, newRank)
	end)
	if not ok then
		return
	end
	apply(player, newRank)
	announce(player, newRank)
end

function RankService.getRank(player: Player): number
	return ranks[player] or 1
end

local function onLoaded(player: Player)
	local data = Deps.data().getData(player)
	if data == nil then
		return
	end
	local stored = Guard.clampFinite(data.rank, 1, #EconomyConfig.RANKS, 1)
	local rank = math.max(math.floor(stored), EconomyConfig.rankForLifetimeMp(data.lifetimeMp))
	if rank ~= data.rank then
		Deps.data().update(player, function(d)
			d.rank = rank
		end)
	end
	apply(player, rank)
end

function RankService.Init() end

function RankService.Start()
	notifyRemote = Remotes.getEvent("Notify")
	effectRemote = Remotes.getEvent("PlayEffect")
	local data = Deps.data()
	data.ProfileLoaded:Connect(onLoaded)
	Players.PlayerRemoving:Connect(function(player: Player)
		ranks[player] = nil
		nextNeed[player] = nil
	end)
	for _, player in Players:GetPlayers() do
		if data.isLoaded(player) then
			onLoaded(player)
		end
	end
end

return RankService
