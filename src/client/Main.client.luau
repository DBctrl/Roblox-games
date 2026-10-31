--!strict
-- Client bootstrap (T-026). Owned by integration-programmer. See docs/architecture.md section 6.
-- Waits for the game to load (so ReplicatedStorage.Shared is replicated), requires the controllers below in
-- order (UI first, then Effects; they never require each other), calls Init() on all, then Start() on all,
-- each Start in its own thread (its errors show with a trace). A listed controller that is not written yet is
-- skipped; an unlisted direct-child ModuleScript is still loaded last in its folder, with a warning.

if not game:IsLoaded() then
	game.Loaded:Wait()
end

type Controller = {
	Init: ((self: any) -> ())?,
	Start: ((self: any) -> ())?,
}

type Entry = { name: string, controller: Controller }

local ORDER: { { folder: string, modules: { string } } } = {
	{
		folder = "UI",
		modules = {
			"NotificationController", -- first, so other controllers' early errors can toast
			"HudController",
			"TapController",
			"ShopController",
			"EggController", -- S2
			"PetsController", -- S2
			"SettingsController", -- S2
			"RewardsController", -- S3
			"DuelController", -- S3
		},
	},
	{
		folder = "Effects",
		modules = {
			"EffectsController",
			"PetFollowController", -- S2
			"CinematicController", -- S2
			"RagdollController", -- S3
		},
	},
}

local function collect(): { Entry }
	local entries: { Entry } = {}
	for _, group in ORDER do
		local folder = script.Parent:FindFirstChild(group.folder)
		if folder == nil then
			continue
		end
		local listed: { [string]: boolean } = {}
		for _, name in group.modules do
			listed[name] = true
			local module = folder:FindFirstChild(name)
			if module and module:IsA("ModuleScript") then
				table.insert(
					entries,
					{ name = `{group.folder}/{name}`, controller = (require :: any)(module) }
				)
			end
		end
		for _, child in folder:GetChildren() do
			if child:IsA("ModuleScript") and not listed[child.Name] then
				warn(
					`[Main] {group.folder}/{child.Name} is not in the bootstrap order; loading it last in its folder`
				)
				table.insert(
					entries,
					{ name = `{group.folder}/{child.Name}`, controller = (require :: any)(child) }
				)
			end
		end
	end
	return entries
end

local entries = collect()

for _, entry in entries do
	local init = entry.controller.Init
	if init then
		local ok, err = xpcall(init, debug.traceback, entry.controller)
		if not ok then
			error(`[Main] {entry.name}.Init failed: {err}`, 0)
		end
	end
end

for _, entry in entries do
	local start = entry.controller.Start
	if start then
		task.spawn(start, entry.controller) -- errors surface in the console with their own trace
	end
end
