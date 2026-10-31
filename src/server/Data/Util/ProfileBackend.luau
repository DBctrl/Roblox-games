--!strict
-- Thin adapter between DataService and the session-locked profile store. Owned by systems-programmer.
-- DataService only ever talks to the `Backend`/`Session` shape below, never to ProfileStore or DataStoreService.
--
-- Backend choice (`ProfileBackend.create`, yields; call from Start(), never Init()):
--   1. ProfileStore (loleris, Wally `[server-dependencies]`, architecture section 6) when
--      ServerScriptService.ServerPackages.ProfileStore exists. Session locking, retries, auto-save and
--      BindToClose are ProfileStore's.
--   2. Otherwise LockedStore (UpdateAsync + session lock + backoff), because T-001 (add ProfileStore) is deferred
--      under D-022. In Studio with API access off it runs on an in-memory store and warns that nothing persists.
--
-- TODO(verify-api): every ProfileStore call below (`ProfileStore.New`, `:StartSessionAsync(key, { Cancel })`,
-- `profile.Data`, `:AddUserId`, `:IsActive`, `:Save`, `:EndSession`, `.OnSessionEnd:Connect`,
-- `.OnAfterSave:Connect`) is written from the ProfileStore README as remembered, not checked against the installed
-- version. integration-programmer checks them when T-001 installs the package; only this file changes if they differ.

local DataStoreService = game:GetService("DataStoreService")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

local LockedStore = require(script.Parent.LockedStore)

export type Session = LockedStore.Session
export type Backend = LockedStore.Backend

local ProfileBackend = {}

local function profileStoreBackend(
	ProfileStore: any,
	storeName: string,
	template: () -> { [any]: any }
): Backend
	local store = ProfileStore.New(storeName, template()) -- TODO(verify-api)
	local active: { [any]: boolean } = {}

	local function startSession(key: string, userId: number, cancel: () -> boolean): (Session?, string?)
		local ok, result = pcall(function()
			-- TODO(verify-api): StartSessionAsync retries and waits for the session lock itself; returns nil on
			-- failure or when Cancel() returns true.
			return store:StartSessionAsync(key, { Cancel = cancel })
		end)
		if not ok then
			return nil, `error: {result}`
		end
		local profile = result
		if profile == nil then
			return nil, if cancel() then "cancelled" else "unavailable"
		end
		pcall(function()
			profile:AddUserId(userId) -- TODO(verify-api): GDPR right-to-erasure link
		end)

		local endListeners: { (reason: string) -> () } = {}
		local ended = false
		local session: Session
		profile.OnSessionEnd:Connect(function() -- TODO(verify-api)
			if ended then
				return
			end
			ended = true
			active[session] = nil
			for _, callback in endListeners do
				task.spawn(callback, "ended")
			end
		end)

		session = {
			data = profile.Data, -- TODO(verify-api): the live table ProfileStore saves
			isActive = function()
				return not ended and profile:IsActive() -- TODO(verify-api)
			end,
			save = function()
				if not ended then
					profile:Save() -- TODO(verify-api)
				end
			end,
			endSession = function()
				if not ended then
					profile:EndSession() -- TODO(verify-api)
				end
			end,
			onSessionEnd = function(callback: (reason: string) -> ())
				table.insert(endListeners, callback)
			end,
			onAfterSave = function(callback: (saved: { [any]: any }) -> ()): () -> ()
				-- TODO(verify-api): OnAfterSave passes the data as it was saved; Connect returns a connection.
				local connection = profile.OnAfterSave:Connect(callback)
				return function()
					connection:Disconnect()
				end
			end,
			saveNow = function(_release: boolean): boolean
				-- Not used with ProfileStore (DataService.saveAndConfirm waits on onAfterSave instead).
				profile:Save()
				return true
			end,
		}
		active[session] = true
		return session, nil
	end

	return {
		name = "ProfileStore",
		startSession = startSession,
		activeCount = function()
			local n = 0
			for _ in active do
				n += 1
			end
			return n
		end,
	}
end

local function findProfileStore(): ModuleScript?
	local packages = ServerScriptService:FindFirstChild("ServerPackages")
	local module = packages and packages:FindFirstChild("ProfileStore")
	if module and module:IsA("ModuleScript") then
		return module
	end
	return nil
end

-- Yields (Studio probe). `template` must return a fresh table each call.
function ProfileBackend.create(storeName: string, template: () -> { [any]: any }): Backend
	local module = findProfileStore()
	if module then
		return profileStoreBackend((require :: any)(module), storeName, template)
	end

	local store: LockedStore.DataStoreLike? = nil
	local ok, result = pcall(function()
		return DataStoreService:GetDataStore(storeName)
	end)
	if ok then
		store = result :: any
		if RunService:IsStudio() then
			-- Studio without "Enable Studio Access to API Services" errors on the first real call; probe once.
			local probeOk = pcall(function()
				(result :: DataStore):GetAsync("__probe")
			end)
			if not probeOk then
				store = nil
			end
		end
	end
	if store == nil then
		if RunService:IsStudio() then
			warn(
				"DataService: DataStore unavailable in Studio; using an in-memory store (nothing will persist)"
			)
			store = LockedStore.memoryStore()
		else
			-- Live server and GetDataStore itself failed: retry with backoff until it works. Never fall back to an
			-- in-memory store live, that would lose data. Players joining meanwhile wait in DataService.waitForData.
			local delay = 1
			while store == nil do
				task.wait(delay)
				delay = math.min(delay * 2, 30)
				local retryOk, retry = pcall(function()
					return DataStoreService:GetDataStore(storeName)
				end)
				if retryOk then
					store = retry :: any
				end
			end
		end
	end
	warn(
		"DataService: ProfileStore package not installed (T-001); using the UpdateAsync session-lock fallback"
	)
	return LockedStore.new(store :: LockedStore.DataStoreLike, { template = template })
end

return table.freeze(ProfileBackend)
