--!strict
-- Fallback session-locked profile backend on plain DataStore `UpdateAsync`. Owned by systems-programmer.
-- Used only while ProfileStore is not installed (T-001 deferred, D-022); ProfileBackend picks ProfileStore when
-- the Wally package is present. Same Session shape as the ProfileStore adapter (see ProfileBackend.luau).
--
-- Record stored under each key: { data = <profile>, meta = { lockId: string?, lockTime: number, saves: number } }
--   * Load: one UpdateAsync claims the lock if it is free, ours, or stale (older than LOCK_TIMEOUT_SEC). A fresh
--     lock held by another session is NOT taken: we retry with exponential backoff (the other server is usually
--     releasing after a server hop), then give up and the caller kicks with "please rejoin".
--   * A nil value inside a successful UpdateAsync is the only case that creates a new profile. A failed call, a
--     corrupt record or a held lock never writes defaults, so a DataStore outage can't wipe a save.
--   * Save: UpdateAsync writes a snapshot only if the lock is still ours; otherwise the session is "lost" (another
--     server took a stale lock) and ends without writing, so two servers never overwrite each other.
--   * Lock ids are per session (server GUID + counter), so a quick rejoin to the same server waits for the old
--     session's release instead of racing it.
--   * Autosave every AUTOSAVE_SEC refreshes the lock; release clears it. Saves on one session are serialised.
-- `new(store, options)` takes any object with `UpdateAsync(self, key, transform)` plus injectable `now`/`wait`,
-- so qa can unit-test outages, held locks and corrupt records with a fake store (no real DataStore).

local HttpService = game:GetService("HttpService")

local ProfileSchema = require(script.Parent.ProfileSchema)

export type DataStoreLike = {
	UpdateAsync: (self: any, key: string, transform: (old: any, keyInfo: any) -> ...any) -> ...any,
}

export type Options = {
	template: () -> { [any]: any },
	now: (() -> number)?, -- default os.time
	wait: ((seconds: number) -> ())?, -- default task.wait
	serverId: string?, -- default a new GUID
	loadBackoff: { number }?, -- seconds between load tries; tries = #loadBackoff + 1
	saveBackoff: { number }?, -- seconds between save tries
	lockTimeoutSec: number?,
	autosaveSec: number?,
	startAutosave: boolean?, -- default true; tests pass false
}

type Listener<A...> = { (A...) -> () }

export type Session = {
	data: { [any]: any },
	isActive: () -> boolean,
	save: () -> (),
	endSession: () -> (),
	onSessionEnd: (callback: (reason: string) -> ()) -> (),
	onAfterSave: (callback: (saved: { [any]: any }) -> ()) -> () -> (), -- returns a disconnect function
	-- test/inspection helpers
	saveNow: (release: boolean) -> boolean, -- yields; true if the snapshot was written
}

export type Backend = {
	name: string,
	startSession: (key: string, userId: number, cancel: () -> boolean) -> (Session?, string?),
	activeCount: () -> number,
}

local LockedStore = {}

LockedStore.LOCK_TIMEOUT_SEC = 300 -- 5 autosaves missed = the server is gone
LockedStore.AUTOSAVE_SEC = 60
LockedStore.LOAD_BACKOFF = table.freeze({ 1, 2, 4, 8, 16 }) -- 6 tries, ~31 s
LockedStore.SAVE_BACKOFF = table.freeze({ 1, 2, 4 }) -- 4 tries

local function emit<A...>(listeners: Listener<A...>, ...: A...)
	for _, callback in listeners do
		task.spawn(callback, ...)
	end
end

function LockedStore.new(store: DataStoreLike, options: Options): Backend
	local now = options.now or os.time
	local wait = options.wait or function(seconds: number)
		task.wait(seconds)
	end
	local serverId = options.serverId or HttpService:GenerateGUID(false)
	local loadBackoff = options.loadBackoff or LockedStore.LOAD_BACKOFF
	local saveBackoff = options.saveBackoff or LockedStore.SAVE_BACKOFF
	local lockTimeout = options.lockTimeoutSec or LockedStore.LOCK_TIMEOUT_SEC
	local autosaveSec = options.autosaveSec or LockedStore.AUTOSAVE_SEC

	local counter = 0
	local active: { [Session]: boolean } = {}
	local autosaveStarted = false

	local function startAutosave()
		if autosaveStarted or options.startAutosave == false then
			return
		end
		autosaveStarted = true
		task.spawn(function()
			while true do
				task.wait(autosaveSec)
				local list = {}
				for session in active do
					table.insert(list, session)
				end
				-- Stagger saves across the interval so a full server doesn't burst the write budget.
				local gap = if #list > 0 then math.min(1, autosaveSec / (#list + 1)) else 0
				for _, session in list do
					if active[session] then
						session.save()
					end
					task.wait(gap)
				end
			end
		end)
	end

	local function startSession(key: string, userId: number, cancel: () -> boolean): (Session?, string?)
		counter += 1
		local lockId = `{serverId}:{counter}`
		local loaded: { [any]: any }? = nil
		local lastReason = "unknown"

		for attempt = 1, #loadBackoff + 1 do
			if cancel() then
				return nil, "cancelled"
			end
			local outcome = "error"
			local ok, err = pcall(function()
				store:UpdateAsync(key, function(old: any)
					local t = now()
					if old == nil then
						outcome = "new"
						local record =
							{ data = options.template(), meta = { lockId = lockId, lockTime = t, saves = 0 } }
						loaded = record.data
						return record, { userId }
					end
					if type(old) ~= "table" or type(old.data) ~= "table" then
						outcome = "corrupt"
						return nil -- cancel the write: never overwrite a record we can't read
					end
					local meta = if type(old.meta) == "table" then old.meta else {}
					local holder = meta.lockId
					local lockTime = if type(meta.lockTime) == "number" then meta.lockTime else 0
					if holder ~= nil and holder ~= lockId and t - lockTime < lockTimeout then
						outcome = "locked"
						return nil
					end
					outcome = "ok"
					meta.lockId = lockId
					meta.lockTime = t
					old.meta = meta
					loaded = old.data
					return old, { userId }
				end)
			end)
			if ok and (outcome == "ok" or outcome == "new") and loaded ~= nil then
				break
			end
			loaded = nil
			lastReason = if ok then outcome else `error: {err}`
			if outcome == "corrupt" then
				return nil, "corrupt"
			end
			if attempt <= #loadBackoff then
				wait(loadBackoff[attempt])
			end
		end

		local data = loaded
		if data == nil then
			return nil, lastReason
		end

		local isActive = true
		local busy = false
		local endListeners: Listener<string> = {}
		local saveListeners: Listener<{ [any]: any }> = {}
		local session: Session

		local function finish(reason: string)
			if not isActive then
				return
			end
			isActive = false
			active[session] = nil
			emit(endListeners, reason)
		end

		-- One write attempt loop. Returns true if written; ends the session if the lock was lost.
		local function saveNow(release: boolean): boolean
			while busy do
				task.wait(0.1)
			end
			if not isActive then
				return false
			end
			busy = true
			local snapshot = ProfileSchema.deepCopy(data)
			local written = false
			local lost = false
			for attempt = 1, #saveBackoff + 1 do
				local ok = pcall(function()
					store:UpdateAsync(key, function(old: any)
						if type(old) ~= "table" or type(old.meta) ~= "table" or old.meta.lockId ~= lockId then
							lost = true
							return nil
						end
						lost = false
						local saves = if type(old.meta.saves) == "number" then old.meta.saves + 1 else 1
						return {
							data = snapshot,
							meta = {
								lockId = if release then nil else lockId,
								lockTime = now(),
								saves = saves,
							},
						}, { userId }
					end)
				end)
				if ok then
					written = not lost
					break
				end
				if attempt <= #saveBackoff then
					wait(saveBackoff[attempt])
				end
			end
			busy = false
			if written then
				emit(saveListeners, snapshot)
			end
			if lost then
				finish("lost")
			elseif release then
				-- Released (or the release failed after every retry: the lock then goes stale in LOCK_TIMEOUT_SEC).
				finish(if written then "released" else "releaseFailed")
			end
			return written
		end

		session = {
			data = data,
			isActive = function()
				return isActive
			end,
			save = function()
				if isActive then
					task.spawn(saveNow, false)
				end
			end,
			endSession = function()
				if isActive then
					task.spawn(saveNow, true)
				end
			end,
			onSessionEnd = function(callback: (reason: string) -> ())
				table.insert(endListeners, callback)
			end,
			onAfterSave = function(callback: (saved: { [any]: any }) -> ()): () -> ()
				table.insert(saveListeners, callback)
				return function()
					local index = table.find(saveListeners, callback)
					if index then
						table.remove(saveListeners, index)
					end
				end
			end,
			saveNow = saveNow,
		}

		if cancel() then
			-- The player left while we were loading: give the lock straight back.
			task.spawn(saveNow, true)
			return nil, "cancelled"
		end
		active[session] = true
		startAutosave()
		return session, nil
	end

	return {
		name = "LockedStore",
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

-- In-memory DataStore stand-in for Studio when API access is off. Nothing persists past the play session.
function LockedStore.memoryStore(): DataStoreLike
	local values: { [string]: any } = {}
	return {
		UpdateAsync = function(_self: any, key: string, transform: (old: any, keyInfo: any) -> ...any): any
			local new = transform(ProfileSchema.deepCopy(values[key]), nil)
			if new ~= nil then
				values[key] = ProfileSchema.deepCopy(new)
			end
			return new
		end,
	}
end

return table.freeze(LockedStore)
