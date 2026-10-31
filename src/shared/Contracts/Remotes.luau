--!strict
-- Single source of truth for every RemoteEvent / RemoteFunction.
-- Owned by integration-programmer. Must match docs/architecture.md "Remotes" table exactly.
-- Server: call Remotes.setup() once at startup. Client/server: Remotes.get(name).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Remotes = {}

export type RemoteName = string

-- name -> "Event" | "Function"
Remotes.Definitions = {
	-- e.g. RequestPurchaseUpgrade = "Event",
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

return Remotes
