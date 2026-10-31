--!strict
-- Single source of truth for every RemoteEvent / RemoteFunction in "Aura Up!" v1.
-- Owned by integration-programmer. Must match docs/architecture.md section 2 "Remotes" exactly.
-- Server: call Remotes.setup() once at startup (the bootstrap does this). Client/server: Remotes.getEvent(name).
-- Payload types live in Contracts/Types.luau. Every C->S handler validates its arguments on the server and
-- applies the token bucket below (rate = tokens per second, burst = bucket size); excess calls are dropped.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Remotes = {}

export type RemoteName =
	-- Client -> Server
	"TapBatch"
	| "RequestBossFight"
	| "BuyTool"
	| "BuyPod"
	| "RequestRebirth"
	| "HatchEgg"
	| "EquipPet"
	| "DeletePets"
	| "DuelChallenge"
	| "DuelRespond"
	| "DuelRematch"
	| "SetDuelBlock"
	| "RequestPurchase"
	| "ClaimDailyReward"
	| "RedeemCode"
	| "SetSetting"
	-- Server -> Client
	| "Notify"
	| "PlayEffect"
	| "HatchResult"
	| "DuelState"

export type RemoteKind = "Event" | "Function"
export type Direction = "C2S" | "S2C"

export type Definition = {
	kind: RemoteKind,
	direction: Direction,
	rate: number?, -- C2S only: tokens refilled per second per player
	burst: number?, -- C2S only: bucket size
}

local definitions: { [RemoteName]: Definition } = {
	-- Client -> Server ------------------------------------------------------------------------------
	TapBatch = { kind = "Event", direction = "C2S", rate = 4, burst = 4 }, -- (count). Gameplay/TapService
	RequestBossFight = { kind = "Event", direction = "C2S", rate = 1, burst = 2 }, -- (bossId). Gameplay/BossService
	BuyTool = { kind = "Event", direction = "C2S", rate = 2, burst = 3 }, -- (toolIndex). Gameplay/ShopService
	BuyPod = { kind = "Event", direction = "C2S", rate = 2, burst = 3 }, -- (podIndex). Gameplay/ShopService
	RequestRebirth = { kind = "Event", direction = "C2S", rate = 0.5, burst = 1 }, -- (). Gameplay/RebirthService
	HatchEgg = { kind = "Event", direction = "C2S", rate = 1, burst = 2 }, -- (eggId, count). Gameplay/PetService
	EquipPet = { kind = "Event", direction = "C2S", rate = 8, burst = 10 }, -- (petUid, equip). Gameplay/PetService
	DeletePets = { kind = "Event", direction = "C2S", rate = 1, burst = 2 }, -- (petUids). Gameplay/PetService
	DuelChallenge = { kind = "Event", direction = "C2S", rate = 0.5, burst = 1 }, -- (targetUserId). DuelService
	DuelRespond = { kind = "Event", direction = "C2S", rate = 1, burst = 2 }, -- (challengerUserId, accept). DuelService
	DuelRematch = { kind = "Event", direction = "C2S", rate = 1, burst = 2 }, -- (accept). Gameplay/DuelService
	SetDuelBlock = { kind = "Event", direction = "C2S", rate = 1, burst = 3 }, -- (targetUserId, blocked). DuelService
	RequestPurchase = { kind = "Event", direction = "C2S", rate = 0.5, burst = 2 }, -- (productKey). Data/Monetization
	ClaimDailyReward = { kind = "Event", direction = "C2S", rate = 0.5, burst = 1 }, -- (). Gameplay/RewardService
	RedeemCode = { kind = "Event", direction = "C2S", rate = 0.33, burst = 2 }, -- (code). Gameplay/RewardService
	SetSetting = { kind = "Event", direction = "C2S", rate = 2, burst = 5 }, -- (key, value). Data/DataService
	-- Server -> Client ------------------------------------------------------------------------------
	Notify = { kind = "Event", direction = "S2C" }, -- (Types.NotifyPayload). UI/NotificationController
	PlayEffect = { kind = "Event", direction = "S2C" }, -- (Types.EffectId, Types.EffectPayload). Effects
	HatchResult = { kind = "Event", direction = "S2C" }, -- (Types.HatchResultPayload). UI/EggController
	DuelState = { kind = "Event", direction = "S2C" }, -- (Types.DuelStatePayload). UI/DuelController
}
Remotes.Definitions = table.freeze(definitions)

local FOLDER_NAME = "Remotes"

function Remotes.setup()
	assert(RunService:IsServer(), "Remotes.setup must run on the server")
	local folder = ReplicatedStorage:FindFirstChild(FOLDER_NAME) or Instance.new("Folder")
	folder.Name = FOLDER_NAME
	for name, def in Remotes.Definitions do
		if not folder:FindFirstChild(name) then
			local remote = Instance.new(if def.kind == "Event" then "RemoteEvent" else "RemoteFunction")
			remote.Name = name
			remote.Parent = folder
		end
	end
	folder.Parent = ReplicatedStorage
end

function Remotes.get(name: RemoteName): Instance
	assert(Remotes.Definitions[name], `Unknown remote "{name}" - add it to Contracts/Remotes.luau`)
	local folder = ReplicatedStorage:WaitForChild(FOLDER_NAME, 10)
	assert(folder, "Remotes folder missing (did the server call Remotes.setup?)")
	local remote = folder:WaitForChild(name, 10)
	assert(remote, `Remote "{name}" not created`)
	return remote
end

function Remotes.getEvent(name: RemoteName): RemoteEvent
	local remote = Remotes.get(name)
	assert(remote:IsA("RemoteEvent"), `Remote "{name}" is not a RemoteEvent`)
	return remote :: RemoteEvent
end

function Remotes.getFunction(name: RemoteName): RemoteFunction
	local remote = Remotes.get(name)
	assert(remote:IsA("RemoteFunction"), `Remote "{name}" is not a RemoteFunction`)
	return remote :: RemoteFunction
end

return Remotes
