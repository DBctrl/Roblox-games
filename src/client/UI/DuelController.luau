--!strict
-- DuelController: the opt-in Mog-Off duel UI (T-054). Owned by systems-programmer.
-- Contract: architecture 1d #30, section 2 #9-#12 and #20, 4c; GDD 6; legal 1.5 and RC-11.
--
-- * "Duel" button (after TutorialDone, GDD 6) opens "Challenge to a Mog-Off": every other player in the server
--   with a Challenge button and a Block / Unblock toggle (the session block list, SetDuelBlock). Challenge fires
--   `DuelChallenge(userId)`; a local 15 s per-target cooldown only greys the button, DuelService checks everything.
-- * Everything after that is drawn from the server's `DuelState` payloads (phase clocks are server timestamps):
--   Invited   -> Accept / Decline / Block with a 10 s timer (auto-decline is the server's).
--   Waiting   -> "Waiting for <name>..." with the timer.
--   Countdown -> 3-2-1.
--   Active    -> tap-off HUD: "TAP!", time left and your local tap count (display only; the server counts).
--   Result    -> the server's scores. Loser text is exactly "Out-glowed! Rematch?" (no insults, legal 1.5).
--   Rematch   -> Rematch / No thanks with a 10 s timer (`DuelRematch`). No paid rematch exists (GDD 6).
--   Ended     -> a short reason line, then everything hides.
-- * Never sends a score, a result or a reward. Never claims "money can't affect PvP" (legal RC-11).

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

local PANEL_NAME = "Duel"
local ROW_PX = 60
local CHALLENGE_COOLDOWN_SEC = 15 -- display mirror of DuelService's per-target cooldown
local SEND_DEBOUNCE_SEC = 1
local ENDED_SHOW_SEC = 2.5
local TICK_SEC = 0.1
local DUEL_NOTE = "Fair fight: pets, multipliers, VIP and boosts don't count in duels."

local PHASES: { [string]: boolean } = {
	Invited = true,
	Waiting = true,
	Countdown = true,
	Active = true,
	Result = true,
	Rematch = true,
	Ended = true,
}

local ENDED_TEXT: { [string]: string } = {
	Declined = "Challenge declined",
	Timeout = "No answer this time",
	Left = "Your opponent left",
	Cancelled = "Duel cancelled",
}

type Row = { userId: number, frame: Frame, challenge: TextButton, block: TextButton }

type Elements = {
	panel: Ui.Panel,
	list: ScrollingFrame,
	status: TextLabel,
	duelButton: TextButton,
	stage: Frame, -- centre card for invite / waiting / result / rematch
	stageTitle: TextLabel,
	stageInfo: TextLabel,
	timer: Frame,
	timerFill: Frame,
	yes: TextButton,
	no: TextButton,
	blockButton: TextButton,
	big: TextLabel, -- countdown digits and "TAP!"
	tapInfo: TextLabel,
}

local DuelController = {}

local ui: Elements? = nil
local rows: { [number]: Row } = {}
local blocked: { [number]: boolean } = {}
local lastChallengeAt: { [number]: number } = {}
local lastSendAt = 0
local state: Types.DuelStatePayload? = nil
local localTaps = 0
local endedToken = 0

local function serverNow(): number
	return workspace:GetServerTimeNow()
end

local function nameOf(userId: number?): string
	local other = if userId then Players:GetPlayerByUserId(userId) else nil
	return if other then other.DisplayName else "Your opponent"
end

local function canSend(): boolean
	local now = os.clock()
	if now - lastSendAt < SEND_DEBOUNCE_SEC then
		return false
	end
	lastSendAt = now
	return true
end

local function finiteOrNil(value: any): number?
	if type(value) == "number" and value == value and math.abs(value) ~= math.huge then
		return value
	end
	return nil
end

-- Validates the server payload shape (never trust shapes, even from the server).
local function parse(payload: any): Types.DuelStatePayload?
	if type(payload) ~= "table" or type(payload.phase) ~= "string" or not PHASES[payload.phase] then
		return nil
	end
	local result = payload.result
	return {
		phase = payload.phase,
		opponentUserId = finiteOrNil(payload.opponentUserId),
		startsAt = finiteOrNil(payload.startsAt),
		endsAt = finiteOrNil(payload.endsAt),
		myScore = finiteOrNil(payload.myScore),
		theirScore = finiteOrNil(payload.theirScore),
		result = if result == "Win"
				or result == "Lose"
				or result == "Draw"
				or result == "Forfeit"
			then result
			else nil,
		rewardCoins = finiteOrNil(payload.rewardCoins),
		reason = if type(payload.reason) == "string" and #payload.reason <= 20 then payload.reason else nil,
	} :: Types.DuelStatePayload
end

-- Challenge list ------------------------------------------------------------------------------------------

local function canChallengeNow(): (boolean, string?)
	if not Ui.boolAttr(Attr.TutorialDone) then
		return false, "Finish the tutorial to unlock Mog-Offs"
	end
	if Ui.boolAttr(Attr.InDuel) or state ~= nil then
		return false, "You're in a Mog-Off"
	end
	local activity = Players.LocalPlayer:GetAttribute(Attr.Activity)
	if activity ~= nil and activity ~= "Idle" then
		return false, "Finish what you're doing first"
	end
	return true, nil
end

local function refreshRows()
	local elements = ui
	if elements == nil then
		return
	end
	local ok, why = canChallengeNow()
	local count = 0
	for userId, row in rows do
		count += 1
		local cooling = os.clock() - (lastChallengeAt[userId] or -math.huge) < CHALLENGE_COOLDOWN_SEC
		if blocked[userId] then
			row.challenge.Text = "Blocked"
			Ui.setEnabled(row.challenge, false)
		elseif cooling then
			row.challenge.Text = "Sent"
			Ui.setEnabled(row.challenge, false)
		else
			row.challenge.Text = "Challenge"
			Ui.setEnabled(row.challenge, ok, Theme.accent)
		end
		row.block.Text = if blocked[userId] then "Unblock" else "Block"
	end
	if not ok then
		elements.status.Text = why or ""
	elseif count == 0 then
		elements.status.Text = "No one else is here yet."
	elseif not Ui.boolAttr(Attr.SettingDuelRequests) then
		elements.status.Text = "Your duel requests are Off in Settings."
	else
		elements.status.Text = DUEL_NOTE
	end
end

local function removeRow(userId: number)
	local row = rows[userId]
	if row then
		row.frame:Destroy()
		rows[userId] = nil
	end
	lastChallengeAt[userId] = nil
end

local function addRow(other: Player, remotes: { [string]: RemoteEvent })
	local elements = ui
	if elements == nil or other == Players.LocalPlayer or rows[other.UserId] then
		return
	end
	local userId = other.UserId
	local frame = Ui.new("Frame", {
		Name = `Player{userId}`,
		BackgroundColor3 = Theme.panelLight,
		Size = UDim2.new(1, -10, 0, ROW_PX),
		Parent = elements.list,
	}, { Ui.corner(0.2) })
	local name = Ui.label({
		Name = "Name",
		Text = other.DisplayName,
		TextXAlignment = Enum.TextXAlignment.Left,
		Position = UDim2.fromScale(0.03, 0.15),
		Size = UDim2.fromScale(0.42, 0.7),
		Parent = frame,
	})
	Ui.textLimit(22).Parent = name
	local challenge = Ui.button({
		Name = "Challenge",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(0.72, 0, 0.5, 0),
		Size = UDim2.new(0.26, 0, 1, -10),
		Parent = frame,
	})
	Ui.textLimit(20).Parent = challenge
	local block = Ui.button({
		Name = "Block",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -6, 0.5, 0),
		Size = UDim2.new(0.25, 0, 1, -10),
		BackgroundColor3 = Theme.panel,
		Parent = frame,
	})
	Ui.textLimit(20).Parent = block
	challenge.Activated:Connect(function()
		if blocked[userId] or not canChallengeNow() then
			return
		end
		if os.clock() - (lastChallengeAt[userId] or -math.huge) < CHALLENGE_COOLDOWN_SEC or not canSend() then
			return
		end
		lastChallengeAt[userId] = os.clock()
		remotes.DuelChallenge:FireServer(userId)
		refreshRows()
	end)
	block.Activated:Connect(function()
		if not canSend() then
			return
		end
		local value = not blocked[userId]
		blocked[userId] = if value then true else nil
		remotes.SetDuelBlock:FireServer(userId, value)
		refreshRows()
	end)
	rows[userId] = { userId = userId, frame = frame, challenge = challenge, block = block }
end

-- Duel stage ----------------------------------------------------------------------------------------------

local function hideStage(elements: Elements)
	elements.stage.Visible = false
	elements.big.Visible = false
	elements.tapInfo.Visible = false
end

local function setChoices(elements: Elements, yesText: string?, noText: string?, showBlock: boolean)
	elements.yes.Visible = yesText ~= nil
	elements.no.Visible = noText ~= nil
	elements.blockButton.Visible = showBlock
	if yesText then
		elements.yes.Text = yesText
	end
	if noText then
		elements.no.Text = noText
	end
end

local function resultText(s: Types.DuelStatePayload): (string, string)
	local scores = ""
	if s.myScore and s.theirScore then
		scores =
			`You {NumberFormat.abbreviate(s.myScore, 1)} - {NumberFormat.abbreviate(s.theirScore, 1)} them`
	end
	if s.result == "Win" then
		local coins = s.rewardCoins or 0
		local reward = if coins > 0
			then ` +{NumberFormat.abbreviate(coins)} Coins`
			else " (reward limit reached for now)"
		return "You win!", scores .. reward
	elseif s.result == "Lose" then
		return "Out-glowed! Rematch?", scores
	elseif s.result == "Draw" then
		return "Draw! Rematch?", scores
	end
	return "Duel over", "Someone left, so nobody gets a reward."
end

local function render()
	local elements = ui
	if elements == nil then
		return
	end
	local s = state
	if s == nil then
		hideStage(elements)
		return
	end
	local opponent = nameOf(s.opponentUserId)
	hideStage(elements)
	if s.phase == "Invited" then
		elements.stage.Visible = true
		elements.stageTitle.Text = `{opponent} challenges you to a Mog-Off!`
		elements.stageInfo.Text = "8 seconds of tapping. Pets, multipliers, VIP and boosts don't count."
		setChoices(elements, "Accept", "Decline", true)
	elseif s.phase == "Waiting" then
		elements.stage.Visible = true
		elements.stageTitle.Text = `Waiting for {opponent}...`
		elements.stageInfo.Text = "They have 10 seconds to answer."
		setChoices(elements, nil, nil, false)
	elseif s.phase == "Countdown" then
		elements.big.Visible = true
	elseif s.phase == "Active" then
		elements.big.Visible = true
		elements.tapInfo.Visible = true
	elseif s.phase == "Result" or s.phase == "Rematch" then
		elements.stage.Visible = true
		local title, info = resultText(s)
		elements.stageTitle.Text = title
		elements.stageInfo.Text = info
		if s.phase == "Rematch" then
			setChoices(elements, "Rematch", "No thanks", false)
		else
			setChoices(elements, nil, nil, false)
		end
	end
end

-- Per-frame-ish clock work (10 Hz): timers, 3-2-1, time left. No per-frame connections.
local function updateClock()
	local elements = ui
	local s = state
	if elements == nil or s == nil then
		return
	end
	local now = serverNow()
	local endsAt = s.endsAt or now
	local startsAt = s.startsAt or now
	local left = math.max(0, endsAt - now)
	local span = math.max(0.1, endsAt - startsAt)
	elements.timerFill.Size = UDim2.fromScale(math.clamp(left / span, 0, 1), 1)
	if s.phase == "Countdown" then
		elements.big.Text = tostring(math.max(1, math.ceil(left)))
	elseif s.phase == "Active" then
		elements.big.Text = "TAP!"
		elements.tapInfo.Text = `{string.format("%.1f", left)} s left   Your taps: {localTaps}`
	end
end

local function onDuelState(payload: any)
	local s = parse(payload)
	if s == nil then
		return
	end
	if s.phase == "Ended" then
		state = nil
		local elements = ui
		local text = ENDED_TEXT[s.reason or ""]
		if elements and text then
			hideStage(elements)
			elements.stage.Visible = true
			elements.stageTitle.Text = text
			elements.stageInfo.Text = ""
			setChoices(elements, nil, nil, false)
			endedToken += 1
			local token = endedToken
			task.delay(ENDED_SHOW_SEC, function()
				if token == endedToken and state == nil then
					hideStage(elements)
				end
			end)
		else
			render()
		end
		refreshRows()
		return
	end
	endedToken += 1
	if s.phase == "Countdown" then
		localTaps = 0
	end
	if s.phase ~= "Invited" and s.phase ~= "Waiting" then
		UiEvents.fireOpenPanel("DuelRunning") -- closes every panel while the duel runs
	end
	state = s
	render()
	updateClock()
	refreshRows()
end

local function onYes(remotes: { [string]: RemoteEvent })
	local s = state
	if s == nil or not canSend() then
		return
	end
	if s.phase == "Invited" and s.opponentUserId then
		remotes.DuelRespond:FireServer(s.opponentUserId, true)
	elseif s.phase == "Rematch" then
		remotes.DuelRematch:FireServer(true)
		local elements = ui
		if elements then
			elements.stageInfo.Text = `Waiting for {nameOf(s.opponentUserId)}...`
			setChoices(elements, nil, nil, false)
		end
	end
end

local function onNo(remotes: { [string]: RemoteEvent }, block: boolean)
	local s = state
	if s == nil or not canSend() then
		return
	end
	if s.phase == "Invited" and s.opponentUserId then
		local id = s.opponentUserId
		if block then
			blocked[id] = true
			remotes.SetDuelBlock:FireServer(id, true)
		end
		remotes.DuelRespond:FireServer(id, false)
	elseif s.phase == "Rematch" then
		remotes.DuelRematch:FireServer(false)
	end
	state = nil
	render()
	refreshRows()
end

-- Build ----------------------------------------------------------------------------------------------------

local function build(): Elements
	local panel = Ui.panel(
		"DuelPanel",
		"Challenge to a Mog-Off",
		20,
		Vector2.new(0.6, 0.72),
		Vector2.new(310, 300),
		Vector2.new(560, 540)
	)
	local list = Ui.scrollList({
		Name = "Players",
		Size = UDim2.fromScale(1, 0.84),
		Parent = panel.body,
	}, 6)
	local status = Ui.label({
		Name = "Status",
		TextWrapped = true,
		TextColor3 = Theme.textDim,
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.fromScale(0.5, 1),
		Size = UDim2.fromScale(1, 0.14),
		Parent = panel.body,
	})
	Ui.textLimit(18).Parent = status

	local screen = Ui.screen("DuelHud", 25)
	-- Left side, mid-height: the Duel button (kept clear of the right-side shop column and the jump button).
	local duelButton = Ui.button({
		Name = "DuelButton",
		Text = "Duel",
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 8, 0.5, 0),
		Size = UDim2.fromScale(0.12, 0.08),
		BackgroundColor3 = Theme.accent,
		Visible = false,
		Parent = screen,
	})
	Ui.textLimit(22).Parent = duelButton

	local stage = Ui.new("Frame", {
		Name = "Stage",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.fromScale(0.5, 0.2),
		Size = UDim2.fromScale(0.56, 0.34),
		BackgroundColor3 = Theme.panel,
		Visible = false,
		Parent = screen,
	}, { Ui.corner(0.08), Ui.stroke(3), Ui.sizeLimit(300, 190, 560, 300) })
	local stageTitle = Ui.label({
		Name = "Title",
		TextColor3 = Theme.accent,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.fromScale(0.5, 0.05),
		Size = UDim2.fromScale(0.92, 0.24),
		Parent = stage,
	})
	Ui.textLimit(30).Parent = stageTitle
	local stageInfo = Ui.label({
		Name = "Info",
		TextWrapped = true,
		TextColor3 = Theme.text,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.fromScale(0.5, 0.31),
		Size = UDim2.fromScale(0.92, 0.2),
		Parent = stage,
	})
	Ui.textLimit(18).Parent = stageInfo
	local timer, timerFill = Ui.meter({
		Name = "Timer",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.fromScale(0.5, 0.53),
		Size = UDim2.fromScale(0.9, 0.07),
		Parent = stage,
	}, Theme.accent)
	local function choice(name: string, x: number, width: number, color: Color3): TextButton
		local button = Ui.button({
			Name = name,
			AnchorPoint = Vector2.new(0, 1),
			Position = UDim2.new(x, 0, 1, -8),
			Size = UDim2.fromScale(width, 0.27),
			BackgroundColor3 = color,
			Parent = stage,
		})
		Ui.textLimit(22).Parent = button
		return button
	end
	local yes = choice("Yes", 0.04, 0.34, Theme.good)
	local no = choice("No", 0.4, 0.3, Theme.bad)
	local blockButton = choice("Block", 0.72, 0.24, Theme.panelLight)
	blockButton.Text = "Block"

	local big = Ui.label({
		Name = "Big",
		TextColor3 = Theme.accent,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.fromScale(0.5, 0.18),
		Size = UDim2.fromScale(0.4, 0.2),
		Visible = false,
		Parent = screen,
	})
	Ui.textLimit(96).Parent = big
	local tapInfo = Ui.label({
		Name = "TapInfo",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.fromScale(0.5, 0.39),
		Size = UDim2.fromScale(0.6, 0.07),
		Visible = false,
		Parent = screen,
	})
	Ui.textLimit(26).Parent = tapInfo

	return {
		panel = panel,
		list = list,
		status = status,
		duelButton = duelButton,
		stage = stage,
		stageTitle = stageTitle,
		stageInfo = stageInfo,
		timer = timer,
		timerFill = timerFill,
		yes = yes,
		no = no,
		blockButton = blockButton,
		big = big,
		tapInfo = tapInfo,
	}
end

local function refreshDuelButton()
	local elements = ui
	if elements then
		elements.duelButton.Visible = Ui.boolAttr(Attr.TutorialDone) and state == nil
	end
end

function DuelController:Init() end

function DuelController:Start()
	local player = Players.LocalPlayer
	local elements = build()
	ui = elements
	local remotes: { [string]: RemoteEvent } = {
		DuelChallenge = Remotes.getEvent("DuelChallenge"),
		DuelRespond = Remotes.getEvent("DuelRespond"),
		DuelRematch = Remotes.getEvent("DuelRematch"),
		SetDuelBlock = Remotes.getEvent("SetDuelBlock"),
	}

	elements.duelButton.Activated:Connect(function()
		UiEvents.fireOpenPanel(PANEL_NAME)
	end)
	UiEvents.OpenPanel:Connect(function(name: string)
		elements.panel.root.Visible = name == PANEL_NAME and Ui.boolAttr(Attr.DataLoaded)
		if elements.panel.root.Visible then
			refreshRows()
		end
	end)
	elements.yes.Activated:Connect(function()
		onYes(remotes)
	end)
	elements.no.Activated:Connect(function()
		onNo(remotes, false)
	end)
	elements.blockButton.Activated:Connect(function()
		onNo(remotes, true)
	end)

	for _, other in Players:GetPlayers() do
		addRow(other, remotes)
	end
	Players.PlayerAdded:Connect(function(other)
		addRow(other, remotes)
		refreshRows()
	end)
	Players.PlayerRemoving:Connect(function(other)
		removeRow(other.UserId)
		blocked[other.UserId] = nil
		refreshRows()
	end)

	Remotes.getEvent("DuelState").OnClientEvent:Connect(function(payload: any)
		onDuelState(payload)
		refreshDuelButton()
	end)
	UiEvents.Tapped:Connect(function()
		local s = state
		if s and s.phase == "Active" then
			localTaps += 1
		end
	end)
	for _, name in { Attr.TutorialDone, Attr.InDuel, Attr.Activity, Attr.SettingDuelRequests } do
		player:GetAttributeChangedSignal(name):Connect(function()
			refreshDuelButton()
			refreshRows()
		end)
	end
	refreshDuelButton()
	refreshRows()

	task.spawn(function()
		local sinceRows = 0
		while player.Parent do
			task.wait(TICK_SEC)
			updateClock()
			sinceRows += TICK_SEC
			if sinceRows >= 1 and elements.panel.root.Visible then
				sinceRows = 0
				refreshRows() -- "Sent" cooldowns run out
			end
		end
	end)
end

return DuelController
