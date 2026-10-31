--!strict
-- QuestService (architecture 1b #18, layer L3). Owned by gameplay-programmer.
-- The tutorial quest chain from GDD 9 (EconomyConfig.QUEST_STEPS): win 5, Hair Gel, beat Bedhead Benny, Ring Light
-- Pod, Bubble Face Mask, rank-up, first egg. No remotes: progress comes only from server signals (BossWon,
-- ToolBought, PodBought, RankUp, Hatched) and the profile, so a client cannot skip a step. State goals (wins,
-- tool, pod, rank) are re-checked on load, so a step already met is passed at once. The chain never goes back.
-- When the last step is done: profile.quest.done, `TutorialDone` attribute, `TutorialCompleted` signal. Duels
-- (DuelService and DataService's DuelRequests setting) and the Starter Pack pop-up timing read it.
-- Sole writer of QuestStep and TutorialDone, and of profile.quest.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BossService = require(script.Parent.BossService)
local Deps = require(script.Parent.Util.Deps)
local EconomyConfig = require(ReplicatedStorage.Shared.Gameplay.EconomyConfig)
local Guard = require(script.Parent.Util.Guard)
local PetService = require(script.Parent.PetService)
local RankService = require(script.Parent.RankService)
local Remotes = require(ReplicatedStorage.Shared.Contracts.Remotes)
local ShopService = require(script.Parent.ShopService)
local Types = require(ReplicatedStorage.Shared.Contracts.Types)

local Attr = Types.PlayerAttr
local STEPS = EconomyConfig.QUEST_STEPS
local LAST = #STEPS

type ProfileData = Types.ProfileData
type Event = { beatBoss: string?, hatch: boolean? }

local completedEvent = Instance.new("BindableEvent")

local QuestService = {}
QuestService.TutorialCompleted = completedEvent.Event -- (player: Player)

local notifyRemote: RemoteEvent? = nil

local function setAttr(player: Player, name: string, value: any)
	if player.Parent == Players and player:GetAttribute(name) ~= value then
		player:SetAttribute(name, value)
	end
end

local function podOwned(data: ProfileData, podIndex: number): boolean
	local mask = math.floor(Guard.clampFinite(data.podsMask, 0, 2 ^ 31, 0))
	return bit32.btest(mask, bit32.lshift(1, podIndex))
end

-- True if step `row` is met by the profile or by the event that just happened.
local function met(player: Player, data: ProfileData, row: EconomyConfig.QuestStep, event: Event?): boolean
	if row.bossWins then
		return Guard.clampFinite(data.stats.bossWins, 0, math.huge, 0) >= row.bossWins
	elseif row.toolIndex then
		return Guard.clampFinite(data.toolIndex, 1, #EconomyConfig.TOOLS, 1) >= row.toolIndex
	elseif row.podIndex then
		return podOwned(data, row.podIndex)
	elseif row.rank then
		return RankService.getRank(player) >= row.rank
	elseif row.beatBoss then
		return event ~= nil and event.beatBoss == row.beatBoss
	elseif row.hatch then
		return event ~= nil and event.hatch == true
	end
	return false
end

local function currentStep(data: ProfileData): number
	if data.quest.done then
		return LAST + 1
	end
	return math.floor(Guard.clampFinite(data.quest.step, 1, LAST, 1))
end

local function refreshAttributes(player: Player, data: ProfileData)
	setAttr(player, Attr.QuestStep, currentStep(data))
	setAttr(player, Attr.TutorialDone, data.quest.done == true)
end

-- Advances through every step that is met now (an event counts for the step it lands on only).
local function advance(player: Player, event: Event?)
	local dataApi = Deps.data()
	local data = dataApi.getData(player)
	if data == nil or data.quest.done then
		return
	end
	local step = currentStep(data)
	local start = step
	local evt = event
	while step <= LAST and met(player, data, STEPS[step], evt) do
		step += 1
		evt = nil -- one event finishes at most one event goal
	end
	if step == start then
		return
	end
	local finished = step > LAST
	dataApi.update(player, function(d)
		if not d.quest.done then
			d.quest.step = math.min(step, LAST)
			d.quest.done = finished
		end
	end)
	local after = dataApi.getData(player)
	if after then
		refreshAttributes(player, after)
	end
	if notifyRemote and player.Parent == Players then
		local text = if finished then "Tutorial done! Duels are unlocked" else `New quest: {STEPS[step].text}`
		local payload: Types.NotifyPayload = { kind = "Success", text = text }
		notifyRemote:FireClient(player, payload)
	end
	if finished then
		completedEvent:Fire(player) -- TelemetryService logs the TutorialDone funnel from the attribute
	end
end

function QuestService.isTutorialDone(player: Player): boolean
	local data = Deps.data().getData(player)
	return data ~= nil and data.quest.done == true
end

function QuestService.Init() end

function QuestService.Start()
	notifyRemote = Remotes.getEvent("Notify")
	local dataApi = Deps.data()

	BossService.BossWon:Connect(function(player: Player, bossId: string)
		advance(player, { beatBoss = bossId })
	end)
	ShopService.ToolBought:Connect(function(player: Player)
		advance(player, nil)
	end)
	ShopService.PodBought:Connect(function(player: Player)
		advance(player, nil)
	end)
	RankService.RankUp:Connect(function(player: Player)
		advance(player, nil)
	end)
	PetService.Hatched:Connect(function(player: Player)
		advance(player, { hatch = true })
	end)

	local function onLoaded(player: Player)
		local data = dataApi.getData(player)
		if data then
			refreshAttributes(player, data)
			advance(player, nil)
		end
	end
	dataApi.ProfileLoaded:Connect(onLoaded)
	for _, player in Players:GetPlayers() do
		if dataApi.isLoaded(player) then
			onLoaded(player)
		end
	end
end

return QuestService
