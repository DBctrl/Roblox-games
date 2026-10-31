--!strict
-- RewardsController: the free 7-day daily reward calendar (T-055). Owned by systems-programmer.
-- Contract: architecture 1d #31, section 2 #14 (ClaimDailyReward, no arguments), 1e (DailyStreak,
-- DailyClaimable, DailyNextClaimUnix written by RewardService); GDD 9 and 10.
--
-- * Opens from the HUD "Daily" button (UiEvents "Daily"), and once per session on its own when a reward is
--   claimable after the first boss win.
-- * Seven day cards with the GDD 10 rewards. Days already claimed in the current streak are ticked; the next day
--   is highlighted. Reading of the attributes: DailyStreak = days claimed in the current streak (0..7), and
--   RewardService sets it back to 0 when a day was missed ("Missing a day restarts at Day 1"), so the next day
--   is (DailyStreak % 7) + 1.
-- * The claim button fires `ClaimDailyReward()` once (debounced); RewardService checks the UTC day and computes the
--   reward. When nothing is claimable it shows the time to the next claim (DailyNextClaimUnix vs server time).
-- * Coin amounts are "minutes of your best boss coins" (GDD 10); the "about" number is BestCoinsPerSec x minutes,
--   for display only. VIP adds only +10 min Hype Snack per claim (GDD 10). Free only: nothing here sells anything.
-- * No codes box in v1 (T-074 is Update 2, D-034).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Contracts = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Contracts")
local NumberFormat = require(Contracts:WaitForChild("NumberFormat"))
local Remotes = require(Contracts:WaitForChild("Remotes"))
local Types = require(Contracts:WaitForChild("Types"))

local Ui = require(script.Parent.Util.Ui)
local UiEvents = require(script.Parent.Util.UiEvents)

local Attr = Types.PlayerAttr
local Theme = Ui.Theme

local PANEL_NAME = "Daily"
local DAYS = 7
local CLAIM_DEBOUNCE_SEC = 2.5 -- ClaimDailyReward allows 0.5/s, burst 1
local AUTO_OPEN_DELAY_SEC = 3

-- GDD 10 calendar. coinMinutes = minutes of the player's best boss coins/s (display estimate only).
type Day = { title: string, coinMinutes: number? }
local CALENDAR: { Day } = {
	{ title = "Coins", coinMinutes = 2 },
	{ title = "Hype Snack 10 min" },
	{ title = "Coins", coinMinutes = 5 },
	{ title = "Free Basic Egg hatch" },
	{ title = "Coin Snack 15 min" },
	{ title = "Coins", coinMinutes = 10 },
	{ title = "Week Streak Aura + Coins", coinMinutes = 15 },
}

type Card = { frame: Frame, stroke: UIStroke, status: TextLabel, info: TextLabel }

type Elements = {
	panel: Ui.Panel,
	cards: { Card },
	claim: TextButton,
	note: TextLabel,
}

local RewardsController = {}

local ui: Elements? = nil
local lastClaimAt = 0
local autoOpened = false

local function streak(): number
	return math.clamp(math.floor(Ui.numAttr(Attr.DailyStreak, 0)), 0, DAYS)
end

local function claimable(): boolean
	return Ui.boolAttr(Attr.DailyClaimable)
end

-- Day 1..7 that the next claim gives.
local function nextDay(): number
	return (streak() % DAYS) + 1
end

local function coinText(minutes: number): string
	local perSec = Ui.numAttr(Attr.BestCoinsPerSec, 0)
	if perSec <= 0 then
		return `{minutes} min of your best boss coins`
	end
	return `{minutes} min of boss coins (about {NumberFormat.abbreviate(perSec * minutes * 60)})`
end

local function refresh()
	local elements = ui
	if elements == nil or not elements.panel.root.Visible then
		return
	end
	local s = streak()
	local canClaim = claimable()
	local upcoming = nextDay()
	-- A full streak that is claimable again starts a new week: nothing in it is claimed yet.
	local claimedThrough = if canClaim and s >= DAYS then 0 else s
	for index, card in elements.cards do
		local day = CALENDAR[index]
		card.info.Text = if day.coinMinutes then `{day.title}: {coinText(day.coinMinutes)}` else day.title
		if index <= claimedThrough then
			card.status.Text = "Claimed"
			card.status.TextColor3 = Theme.good
			card.frame.BackgroundColor3 = Theme.panel
			card.stroke.Color = Theme.good
		elseif index == upcoming then
			card.status.Text = if canClaim then "Today!" else "Next"
			card.status.TextColor3 = Theme.accent
			card.frame.BackgroundColor3 = Theme.panelLight
			card.stroke.Color = Theme.accent
		else
			card.status.Text = ""
			card.frame.BackgroundColor3 = Theme.panelLight
			card.stroke.Color = Theme.stroke
		end
	end
	if canClaim then
		elements.claim.Text = `Claim Day {upcoming}`
		Ui.setEnabled(elements.claim, true, Theme.good)
	else
		local left = Ui.numAttr(Attr.DailyNextClaimUnix, 0) - workspace:GetServerTimeNow()
		elements.claim.Text = if left > 0
			then `Next reward in {NumberFormat.duration(left)}`
			else "Come back soon"
		Ui.setEnabled(elements.claim, false)
	end
	local vip = if Ui.boolAttr(Attr.Vip) then " VIP: +10 min Hype Snack on each claim." else ""
	elements.note.Text = `Free every day. Missing a day restarts at Day 1.{vip}`
end

local function onClaim(remote: RemoteEvent)
	if not claimable() then
		return
	end
	local now = os.clock()
	if now - lastClaimAt < CLAIM_DEBOUNCE_SEC then
		return
	end
	lastClaimAt = now
	remote:FireServer()
end

local function build(remote: RemoteEvent): Elements
	local panel = Ui.panel(
		"DailyRewards",
		"Daily Rewards",
		20,
		Vector2.new(0.7, 0.78),
		Vector2.new(320, 320),
		Vector2.new(660, 560)
	)
	local grid = Ui.new("Frame", {
		Name = "Days",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 0.68),
		Parent = panel.body,
	}, {
		Ui.new("UIGridLayout", {
			CellSize = UDim2.fromScale(0.23, 0.46),
			CellPadding = UDim2.fromScale(0.02, 0.04),
			HorizontalAlignment = Enum.HorizontalAlignment.Center,
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
	})
	local cards: { Card } = {}
	for index = 1, DAYS do
		local stroke = Ui.new("UIStroke", { Color = Theme.stroke, Thickness = 2 })
		local frame = Ui.new("Frame", {
			Name = `Day{index}`,
			LayoutOrder = index,
			BackgroundColor3 = Theme.panelLight,
			Parent = grid,
		}, { Ui.corner(0.12), stroke })
		local title = Ui.label({
			Name = "Title",
			Text = `Day {index}`,
			Position = UDim2.fromScale(0.05, 0.03),
			Size = UDim2.fromScale(0.9, 0.22),
			Parent = frame,
		})
		Ui.textLimit(20).Parent = title
		local info = Ui.label({
			Name = "Info",
			TextWrapped = true,
			TextColor3 = Theme.textDim,
			Position = UDim2.fromScale(0.05, 0.27),
			Size = UDim2.fromScale(0.9, 0.5),
			Parent = frame,
		})
		Ui.textLimit(14, 8).Parent = info
		local status = Ui.label({
			Name = "Status",
			Position = UDim2.fromScale(0.05, 0.78),
			Size = UDim2.fromScale(0.9, 0.19),
			Parent = frame,
		})
		Ui.textLimit(16).Parent = status
		cards[index] = { frame = frame, stroke = stroke, status = status, info = info }
	end
	local claim = Ui.button({
		Name = "Claim",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.fromScale(0.5, 0.71),
		Size = UDim2.fromScale(0.6, 0.15),
		Parent = panel.body,
	})
	Ui.textLimit(26).Parent = claim
	claim.Activated:Connect(function()
		onClaim(remote)
	end)
	local note = Ui.label({
		Name = "Note",
		TextWrapped = true,
		TextColor3 = Theme.textDim,
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.fromScale(0.5, 1),
		Size = UDim2.fromScale(1, 0.12),
		Parent = panel.body,
	})
	Ui.textLimit(16).Parent = note
	return { panel = panel, cards = cards, claim = claim, note = note }
end

local function maybeAutoOpen()
	if
		autoOpened
		or not claimable()
		or not Ui.boolAttr(Attr.FirstWin)
		or not Ui.boolAttr(Attr.DataLoaded)
	then
		return
	end
	autoOpened = true
	task.delay(AUTO_OPEN_DELAY_SEC, function()
		if claimable() then
			UiEvents.fireOpenPanel(PANEL_NAME)
		end
	end)
end

function RewardsController:Init() end

function RewardsController:Start()
	local player = Players.LocalPlayer
	local elements = build(Remotes.getEvent("ClaimDailyReward"))
	ui = elements

	UiEvents.OpenPanel:Connect(function(name: string)
		elements.panel.root.Visible = name == PANEL_NAME and Ui.boolAttr(Attr.DataLoaded)
		refresh()
	end)
	for _, name in
		{
			Attr.DailyStreak,
			Attr.DailyClaimable,
			Attr.DailyNextClaimUnix,
			Attr.BestCoinsPerSec,
			Attr.Vip,
		}
	do
		player:GetAttributeChangedSignal(name):Connect(refresh)
	end
	for _, name in { Attr.DailyClaimable, Attr.FirstWin, Attr.DataLoaded } do
		player:GetAttributeChangedSignal(name):Connect(maybeAutoOpen)
	end
	maybeAutoOpen()

	-- The "Next reward in" countdown: once per second while the panel is open.
	task.spawn(function()
		while player.Parent do
			task.wait(1)
			if elements.panel.root.Visible and not claimable() then
				refresh()
			end
		end
	end)
end

return RewardsController
