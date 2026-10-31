--!strict
-- Server bootstrap. Owned by integration-programmer.
-- Requires every ModuleScript directly inside Data, World, Gameplay (in that order),
-- calls Init() on all of them, then Start() on all of them.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Remotes =
	require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Contracts"):WaitForChild("Remotes"))

type Service = {
	Init: ((self: any) -> ())?,
	Start: ((self: any) -> ())?,
}

Remotes.setup()

local services: { Service } = {}
for _, folderName in { "Data", "World", "Gameplay" } do
	local folder = script.Parent:FindFirstChild(folderName)
	if folder then
		for _, child in folder:GetChildren() do
			if child:IsA("ModuleScript") then
				table.insert(services, (require :: any)(child))
			end
		end
	end
end

for _, service in services do
	if service.Init then
		service:Init()
	end
end
for _, service in services do
	if service.Start then
		task.spawn(service.Start :: any, service)
	end
end
