--!strict
-- Client bootstrap. Owned by integration-programmer.
-- Requires every ModuleScript directly inside UI and Effects, then Init() all, then Start() all.

type Controller = {
	Init: ((self: any) -> ())?,
	Start: ((self: any) -> ())?,
}

local controllers: { Controller } = {}
for _, folderName in { "UI", "Effects" } do
	local folder = script.Parent:FindFirstChild(folderName)
	if folder then
		for _, child in folder:GetChildren() do
			if child:IsA("ModuleScript") then
				table.insert(controllers, (require :: any)(child))
			end
		end
	end
end

for _, controller in controllers do
	if controller.Init then
		controller:Init()
	end
end
for _, controller in controllers do
	if controller.Start then
		task.spawn(controller.Start :: any, controller)
	end
end
