--!strict
-- Single source of truth for every RemoteEvent / RemoteFunction.
-- Owned by integration-programmer. Must match docs/architecture.md section 2 "Remotes" exactly.
-- Server: call Remotes.setup() once at startup (the bootstrap does this). Client/server: Remotes.getEvent(name).
-- Payload types live in Contracts/Types.luau.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Remotes = {}

export type RemoteName = "RequestRebirth" | "ClaimDailyReward" | "SetDonorPrivacy" | "Notify" | "PlayEffect"

-- name -> "Event" | "Function"
Remotes.Definitions = {
	-- Client -> Server
	RequestRebirth = "Event", -- (no args). Handler: Gameplay/RebirthService
	ClaimDailyReward = "Event", -- (no args). Handler: Gameplay/DailyRewardService
	SetDonorPrivacy = "Event", -- (hidden: boolean). Handler: Data/DataService
	-- Server -> Client
	Notify = "Event", -- (payload: Types.NotifyPayload). Handler: client UI/NotificationController
	PlayEffect = "Event", -- (effect: Types.EffectId, payload: Types.EffectPayload). Handler: client Effects/EffectsController
} :: { [RemoteName]: "Event" | "Function" }

local FOLDER_NAME = "Remotes"

function Remotes.setup()
	assert(RunService:IsServer(), "Remotes.setup must run on the server")
	local folder = ReplicatedStorage:FindFirstChild(FOLDER_NAME) or Instance.new("Folder")
	folder.Name = FOLDER_NAME
	for name, kind in Remotes.Definitions do
		if not folder:FindFirstChild(name) then
			local remote = Instance.new(if kind == "Event" then "RemoteEvent" else "RemoteFunction")
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
