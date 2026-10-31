--!strict
-- ActivityService (architecture 1b #8, layer L0). Owned by gameplay-programmer.
-- One exclusive activity per player: Idle, BossFight, Hatching or Duel. Every activity that must not overlap
-- (boss fight, hatch, duel) starts with `tryBegin` and ends with `finish`. Sole writer of the `Activity` attribute.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Types = require(ReplicatedStorage.Shared.Contracts.Types)

local ATTR = Types.PlayerAttr.Activity

local ActivityService = {}

local current: { [Player]: Types.Activity } = {}

local function write(player: Player, activity: Types.Activity)
	if player:GetAttribute(ATTR) ~= activity then
		player:SetAttribute(ATTR, activity)
	end
end

-- Starts `activity` if the player is Idle. False if busy, left, or `activity` is "Idle".
function ActivityService.tryBegin(player: Player, activity: Types.Activity): boolean
	if activity == "Idle" or player.Parent ~= Players then
		return false
	end
	if (current[player] or "Idle") ~= "Idle" then
		return false
	end
	current[player] = activity
	write(player, activity)
	return true
end

-- Ends `activity` (no-op if the player is doing something else, so a late timer can't end a newer activity).
function ActivityService.finish(player: Player, activity: Types.Activity)
	if current[player] ~= activity then
		return
	end
	current[player] = "Idle"
	if player.Parent == Players then
		write(player, "Idle")
	end
end

function ActivityService.get(player: Player): Types.Activity
	return current[player] or "Idle"
end

function ActivityService.Init() end

function ActivityService.Start()
	local function onAdded(player: Player)
		if current[player] == nil then
			current[player] = "Idle"
			write(player, "Idle")
		end
	end
	Players.PlayerAdded:Connect(onAdded)
	for _, player in Players:GetPlayers() do
		onAdded(player)
	end
	Players.PlayerRemoving:Connect(function(player: Player)
		current[player] = nil
	end)
end

return ActivityService
