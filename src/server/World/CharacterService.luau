--!strict
-- CharacterService (T-017 basic). Owned by world-programmer. Server only.
-- The ONLY writer of Humanoid WalkSpeed / JumpPower (architecture 1e). Other services ask through
-- setSpeedMultiplier (Speed Sneakers) and reason-keyed setMovementLocked (duels, cinematics).
-- State is kept per player, not per character, and re-applied on every respawn.
-- setLook is a stub until T-038 (rank looks and fits).

local Players = game:GetService("Players")

local BASE_WALK_SPEED = 16 -- Roblox default
local BASE_JUMP_POWER = 50 -- Roblox default
local MIN_SPEED_MULT = 0.25
local MAX_SPEED_MULT = 3
local MAX_REASON_LEN = 32
local HUMANOID_WAIT_SEC = 5

type PlayerState = {
	speedMult: number,
	locks: { [string]: true },
	lookId: string?,
}

local CharacterService = {}

local states: { [Player]: PlayerState } = {}

local function stateOf(player: Player): PlayerState?
	if player.Parent ~= Players then
		return nil
	end
	local state = states[player]
	if state == nil then
		state = { speedMult = 1, locks = {}, lookId = nil }
		states[player] = state
	end
	return state
end

local function isLocked(state: PlayerState): boolean
	return next(state.locks) ~= nil
end

local function humanoidOf(player: Player): Humanoid?
	local character = player.Character
	return if character then character:FindFirstChildOfClass("Humanoid") else nil
end

local function apply(player: Player)
	local state = states[player]
	local humanoid = humanoidOf(player)
	if state == nil or humanoid == nil then
		return
	end
	humanoid.UseJumpPower = true
	if isLocked(state) then
		humanoid.WalkSpeed = 0
		humanoid.JumpPower = 0
	else
		humanoid.WalkSpeed = BASE_WALK_SPEED * state.speedMult
		humanoid.JumpPower = BASE_JUMP_POWER
	end
end

local function onCharacterAdded(player: Player, character: Model)
	local humanoid = character:WaitForChild("Humanoid", HUMANOID_WAIT_SEC)
	if humanoid == nil or player.Character ~= character then
		return
	end
	apply(player)
end

local function onPlayerAdded(player: Player)
	if states[player] ~= nil then
		return -- already handled (joined between Connect and GetPlayers)
	end
	stateOf(player)
	player.CharacterAdded:Connect(function(character)
		onCharacterAdded(player, character)
	end)
	if player.Character then
		task.spawn(onCharacterAdded, player, player.Character)
	end
end

function CharacterService:Init() end

function CharacterService:Start()
	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(function(player)
		states[player] = nil
	end)
	for _, player in Players:GetPlayers() do
		task.spawn(onPlayerAdded, player)
	end
end

-- Walk speed = 16 x mult (clamped 0.25..3). 1 = normal; Speed Sneakers use 1.5. Never yields.
function CharacterService.setSpeedMultiplier(player: Player, mult: number)
	if typeof(mult) ~= "number" or mult ~= mult or math.abs(mult) == math.huge then
		return
	end
	local state = stateOf(player)
	if state == nil then
		return
	end
	local clamped = math.clamp(mult, MIN_SPEED_MULT, MAX_SPEED_MULT)
	if state.speedMult == clamped then
		return
	end
	state.speedMult = clamped
	apply(player)
end

function CharacterService.getSpeedMultiplier(player: Player): number
	local state = states[player]
	return if state then state.speedMult else 1
end

-- Freezes walking and jumping while any reason holds a lock ("Duel", "Cinematic", ...). Each reason
-- is independent: unlocking "Duel" keeps a "Cinematic" lock. Survives respawn. Never yields.
function CharacterService.setMovementLocked(player: Player, reason: string, locked: boolean)
	if
		typeof(reason) ~= "string"
		or #reason == 0
		or #reason > MAX_REASON_LEN
		or typeof(locked) ~= "boolean"
	then
		return
	end
	local state = stateOf(player)
	if state == nil then
		return
	end
	local wasLocked = isLocked(state)
	state.locks[reason] = if locked then true else nil
	if wasLocked ~= isLocked(state) then
		apply(player)
	end
end

function CharacterService.isMovementLocked(player: Player): boolean
	local state = states[player]
	return state ~= nil and isLocked(state)
end

-- Stores the rank look id. Applying accessories (max 6, respects ShowOwnLook) is T-038.
function CharacterService.setLook(player: Player, lookId: string)
	if typeof(lookId) ~= "string" or #lookId > 64 then
		return
	end
	local state = stateOf(player)
	if state then
		state.lookId = lookId
	end
end

return CharacterService
