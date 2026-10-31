--!strict
-- Server bootstrap (T-026). Owned by integration-programmer. See docs/architecture.md section 6.
-- 1. Remotes.setup() creates every remote from Contracts/Remotes.
-- 2. Requires the services below in dependency order (Data -> World -> Gameplay L0..L3, architecture 1a).
--    A listed service that is not written yet is skipped. A direct-child ModuleScript that is not listed is
--    still loaded (after the listed ones, with a warning) so a new service is never silently dead; add it here.
-- 3. Calls Init() on every service in that order (no yields, no cross-service calls). An Init error stops boot.
-- 4. Calls Start() on every service in the same order, each in its own thread (Start may yield).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Remotes =
	require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Contracts"):WaitForChild("Remotes"))

type Service = {
	Init: ((self: any) -> ())?,
	Start: ((self: any) -> ())?,
}

type Entry = { name: string, service: Service }

-- Dependency order. Later sprints only fill in modules that are already listed here.
local ORDER: { { folder: string, modules: { string } } } = {
	{
		folder = "Data",
		modules = {
			"DataService",
			"ComplianceService",
			"TelemetryService", -- S2
			"MonetizationService", -- S3
			"LeaderboardService", -- S3
		},
	},
	{
		folder = "World",
		modules = { "ZoneService", "CharacterService" },
	},
	{
		folder = "Gameplay",
		modules = {
			-- L0
			"ActivityService",
			"MultiplierService",
			-- L1
			"RankService",
			"ShopService",
			"PetService", -- S2
			"BossService",
			-- L2
			"TapService",
			"RebirthService", -- S2
			-- L3
			"IdleService", -- S2
			"DuelService", -- S3
			"QuestService", -- S3
			"RewardService", -- S3
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
				table.insert(entries, { name = `{group.folder}/{name}`, service = (require :: any)(module) })
			end
		end
		for _, child in folder:GetChildren() do
			if child:IsA("ModuleScript") and not listed[child.Name] then
				warn(
					`[Main] {group.folder}/{child.Name} is not in the bootstrap order; loading it last in its folder`
				)
				table.insert(
					entries,
					{ name = `{group.folder}/{child.Name}`, service = (require :: any)(child) }
				)
			end
		end
	end
	return entries
end

Remotes.setup()

local entries = collect()

for _, entry in entries do
	local init = entry.service.Init
	if init then
		local ok, err = xpcall(init, debug.traceback, entry.service)
		if not ok then
			error(`[Main] {entry.name}.Init failed: {err}`, 0)
		end
	end
end

for _, entry in entries do
	local start = entry.service.Start
	if start then
		task.spawn(start, entry.service) -- errors surface in the console with their own trace
	end
end
