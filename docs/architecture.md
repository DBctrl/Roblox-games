# Architecture: Candy Factory Tycoon v1
_Owned by integration-programmer. Sections: see .claude/agents/integration-programmer.md. Version 1, 2026-10-31 (D-009).
Source of truth for code contracts: `src/shared/Contracts/Remotes.luau` and `src/shared/Contracts/Types.luau`.
Both must match this file. Includes lawyer rulings D-008 (no group bonus, shop hides owned/lower tiers, donor-board opt-out)._

## 0. Ground rules
- **Server-authoritative economy.** All Cash math runs in `src/server/Gameplay`. Candy on belts is client-only
  visuals in `src/client/Effects`: no physical candy parts on the server, no remote per candy, nothing to exploit.
- **Pads, gates and the seller rebirth button are physical** and detected on the server (`BasePart.Touched`,
  `ProximityPrompt.Triggered`), so they need no remotes. Only UI-initiated actions use remotes.
- **State reaches clients through attributes** (Player and plot attributes, one writer each), not remotes.
  Remotes are only for UI actions (C->S) and one-shot toasts/effects (S->C).
- **Folder boundaries.** Each programmer edits only their folders (CLAUDE.md). Modules may `require` (read)
  any other folder's public API listed here, never edit it. Anything shared that is not in a programmer's
  folder lives in `src/shared/Contracts` and changes only through a Contract request (section 6).
- **Cross-module calls only after `Init()`.** `Init()` sets up local state and never yields or calls other
  services. Cross-service calls and signal connections happen in `Start()` or later.
- **Signals** are `BindableEvent`s owned by the emitting service and exposed as `RBXScriptSignal`
  (`Service.Something: RBXScriptSignal`). No signal library.
- **Only direct-child ModuleScripts are services.** The bootstraps require every ModuleScript directly in
  `Data`, `World`, `Gameplay` (server) and `UI`, `Effects` (client). Put helper modules in a subfolder
  (e.g. `src/server/Gameplay/Util/`) so the bootstrap does not treat them as services.

## 1. Module map
Path prefix: `ServerScriptService.Server` = `src/server`, `ReplicatedStorage.Shared` = `src/shared`,
`StarterPlayerScripts.Client` = `src/client`. `T.` = `Contracts/Types`.

### 1a. Server
| Module | Owner | Folder | Responsibility |
|---|---|---|---|
| DataService | systems-programmer | `src/server/Data` | ProfileStore sessions, Data API, Player data attributes, leaderstats, `SetDonorPrivacy` handler, BindToClose |
| MonetizationService | systems-programmer | `src/server/Data` | Multiplier-pass ownership (`UserOwnsGamePassAsync`, `PromptGamePassPurchaseFinished`), the only `ProcessReceipt`, donation rewards |
| LeaderboardService | systems-programmer | `src/server/Data` | 3 OrderedDataStores, 60 s write/refresh, hub boards (tag `Leaderboard`), donor opt-out |
| PlotService | world-programmer | `src/server/World` | 6 plots, claim gate + 20 s auto-claim, ownership, release on leave, pad touch detection, pad reveal (only next 2 pads shown), seller rebirth prompt |
| IncomeService | gameplay-programmer | `src/server/Gameplay` | 1 Hz income tick, multipliers, `IncomePerSec`/`TotalMultiplier` attributes |
| PurchaseService | gameplay-programmer | `src/server/Gameplay` | Validates and applies dropper/upgrade purchases from `PlotService.PadTouched` |
| RebirthService | gameplay-programmer | `src/server/Gameplay` | `RequestRebirth` handler + seller prompt, reset, `RebirthCost` attribute |
| DailyRewardService | gameplay-programmer | `src/server/Gameplay` | `ClaimDailyReward` handler, 7-day streak, `Daily*` attributes |
| BadgeAwardService | gameplay-programmer | `src/server/Gameplay` | Welcome / FirstRebirth / Rebirth5 / Rebirth10 via `BadgeService:AwardBadge` |

Public functions (`self` methods are called with `:`; plain functions with `.`; all yield-free unless marked **yields**):

**DataService** (`src/server/Data/DataService.luau`): see section 3 "Data API".

**MonetizationService** (`src/server/Data/MonetizationService.luau`)
```luau
MonetizationService.PassTierChanged: RBXScriptSignal -- (player: Player, tier: T.PassTier)
function MonetizationService.getPassTier(player: Player): T.PassTier       -- 0 until checked
function MonetizationService.getPassMultiplier(player: Player): number     -- 1, 2, 4, 8 or 16
```
Purchases are prompted on the client (`MarketplaceService:PromptGamePassPurchase` / `PromptProductPurchase`
from UI), so no purchase remote exists. No other module may assign `MarketplaceService.ProcessReceipt`.

**LeaderboardService** (`src/server/Data/LeaderboardService.luau`): no public functions (reads DataService itself).

**PlotService** (`src/server/World/PlotService.luau`)
```luau
PlotService.PlotClaimed: RBXScriptSignal            -- (player: Player, plotId: T.PlotId)
PlotService.PlotReleased: RBXScriptSignal           -- (player: Player, plotId: T.PlotId), fires on leave
PlotService.PadTouched: RBXScriptSignal             -- (player: Player, plotId: T.PlotId, padId: T.PadId)
                                                    --   only for the plot owner, Available pads, 0.5 s debounce per pad
PlotService.RebirthPromptTriggered: RBXScriptSignal -- (player: Player, plotId: T.PlotId), owner only
function PlotService.getPlotId(player: Player): T.PlotId?
function PlotService.getOwner(plotId: T.PlotId): Player?
function PlotService.getPlotModel(plotId: T.PlotId): Model?
function PlotService.setProgress(plotId: T.PlotId, progress: T.PlotProgress): ()
    -- sets plot attributes and every pad's PadState/PadLevel; reveals the next 2 pads in EconomyConfig order
```

**IncomeService** (`src/server/Gameplay/IncomeService.luau`)
```luau
function IncomeService.getBaseIncomePerSecond(player: Player): number -- droppers x Gears x Glaze x Rebirth, no pass
function IncomeService.getIncomePerSecond(player: Player): number     -- base x PassMult
function IncomeService.getTotalMultiplier(player: Player): number     -- Glaze x Rebirth x Pass (for client pops)
function IncomeService.refresh(player: Player): ()                    -- recompute after purchase/rebirth/pass change
```
Formula (GDD 5): per dropper, every `interval(gearsLevel)` seconds, `value x GlazeMult x RebirthMult x PassMult`.
Implemented as one server loop at 1 Hz with a per-dropper time accumulator, so Cash and its attribute change
at most once per second per player. **No group bonus** (D-008).

**PurchaseService** (`src/server/Gameplay/PurchaseService.luau`)
```luau
function PurchaseService.tryPurchase(player: Player, padId: T.PadId): (boolean, string?) -- ok, failure reason
```
Validation: profile loaded; player owns the plot; pad is the next dropper in order or an unlocked upgrade
below level 3; `DataService.trySpendCash` succeeds. On success: `DataService.update`, `PlotService.setProgress`,
`IncomeService.refresh`, `PlayEffect("Purchase")` to all clients. On "not enough Cash": `Notify` Error (max 1 per 2 s).

**RebirthService** (`src/server/Gameplay/RebirthService.luau`)
```luau
function RebirthService.getRebirthCost(player: Player): number   -- EconomyConfig.rebirthCost(rebirths + 1)
function RebirthService.tryRebirth(player: Player): (boolean, string?)
```
Atomic reset in one `DataService.update`: cash = START_CASH (50), droppersOwned = 1, upgrades = 0, rebirths += 1.

**DailyRewardService** (`src/server/Gameplay/DailyRewardService.luau`)
```luau
function DailyRewardService.tryClaim(player: Player): (boolean, string?)
```
Uses server `os.time()` only. Once per UTC day; streak resets if `now - lastClaimUnix > 48 h`. Reward =
base $/s x GDD seconds (min $100), never multiplied by passes. Re-checks `DailyClaimable` once per minute.

**BadgeAwardService** (`src/server/Gameplay/BadgeAwardService.luau`)
```luau
function BadgeAwardService.award(player: Player, key: T.BadgeKey): () -- **yields** (call in task.spawn); idempotent via profile.badges
```

### 1b. Shared (read-only for everyone except the owner)
| Module | Owner | Folder | Contents |
|---|---|---|---|
| Contracts/Remotes | integration-programmer | `src/shared/Contracts` | remote list, `setup`, `get`, `getEvent`, `getFunction` |
| Contracts/Types | integration-programmer | `src/shared/Contracts` | exported types, `PlayerAttr`, `PlotAttr`, `Tag`, schema version |
| Gameplay/EconomyConfig | gameplay-programmer | `src/shared/Gameplay` | all balance constants + pure functions (below) |
| World/PlotLayout | world-programmer | `src/shared/World` | pure accessors for builder's plot model (below) |
| Physics/CandyConfig | physics-programmer | `src/shared/Physics` | visual constants: pool size, belt speed, pop style |

```luau
-- EconomyConfig (pure, no Roblox services). Used by Gameplay, World (pad order), UI and Effects.
EconomyConfig.START_CASH: number                    -- 50
EconomyConfig.DROPPERS: { { name: string, cost: number, value: number } } -- 10 entries, index = dropper #
EconomyConfig.UPGRADES: { [T.UpgradeId]: { costs: { number }, unlockAfterDropper: number } }
EconomyConfig.PAD_ORDER: { T.PadId }                -- fixed reveal order
EconomyConfig.BADGE_IDS: { [T.BadgeKey]: number }   -- 0 = not created yet (skip award)
function EconomyConfig.interval(gearsLevel: number): number      -- 2.0 / 1.6 / 1.33 / 1.0
function EconomyConfig.glazeMult(glazeLevel: number): number     -- 1 / 1.5 / 2 / 3
function EconomyConfig.rebirthMult(rebirths: number): number     -- 1 + 0.5 x rebirths
function EconomyConfig.rebirthCost(n: number): number            -- 6e6 x 2^(n-1)
function EconomyConfig.padCost(padId: T.PadId, level: number): number?

-- PlotLayout (pure; nil-safe because StreamingEnabled may not have streamed the part in yet)
function PlotLayout.getPlotModels(): { Model }                   -- CollectionService tag "Plot"
function PlotLayout.getGate(plot: Model): BasePart?
function PlotLayout.getPad(plot: Model, padId: T.PadId): BasePart?
function PlotLayout.getDropper(plot: Model, index: number): Model?
function PlotLayout.getDropperSpout(plot: Model, index: number): Attachment?
function PlotLayout.getConveyorPath(plot: Model): { Vector3 }    -- ordered waypoints, spout area -> seller
function PlotLayout.getSeller(plot: Model): BasePart?
```

### 1c. Client
| Controller | Owner | Folder | Responsibility |
|---|---|---|---|
| HudController | systems-programmer | `src/client/UI` | Cash, $/s, rebirth bar + button (fires `RequestRebirth`), onboarding hint/arrow until `PlotId` > 0, K/M/B/T suffixes |
| ShopController | systems-programmer | `src/client/UI` | Pass ladder + donations; prompts purchases; hides/disables tiers <= `PassTier` with "does not stack" text (D-008); donor-board opt-out toggle (fires `SetDonorPrivacy`) |
| DailyRewardController | systems-programmer | `src/client/UI` | Popup from `Daily*` attributes, fires `ClaimDailyReward` |
| NotificationController | systems-programmer | `src/client/UI` | `Notify` handler, toast queue (max 3 visible) |
| CandyController | physics-programmer | `src/client/Effects` | Client-only candy on belts for nearby plots, pooled (max 40 per plot) |
| EffectsController | physics-programmer | `src/client/Effects` | `PlayEffect` handler, seller "+$" pops, purchase/rebirth/donation effects |
| PadVisualController | physics-programmer | `src/client/Effects` | Local pad tint (green when local `Cash` >= cost), dropper idle animations |

Client controllers have **no public functions**: UI and Effects never `require` each other. They read attributes,
`EconomyConfig`, `PlotLayout`, `CandyConfig`, and the remotes below.

### 1d. Attribute contract (one writer each; names in `Types.PlayerAttr` / `Types.PlotAttr`)
| Instance | Attribute | Type | Writer |
|---|---|---|---|
| Player | DataLoaded, Cash, Rebirths, HideFromDonorBoard | boolean, number, number, boolean | DataService |
| Player | PassTier | number 0..4 | MonetizationService |
| Player | PlotId | number, 0 = none | PlotService |
| Player | IncomePerSec, TotalMultiplier | number | IncomeService |
| Player | RebirthCost | number | RebirthService |
| Player | DailyStreak, DailyClaimable, DailyNextClaimUnix | number, boolean, number | DailyRewardService |
| Plot model | PlotId | number | builder (in place) |
| Plot model | OwnerUserId, DroppersOwned, GearsLevel, GlazeLevel | number | PlotService |
| Pad part | PadState, PadLevel | T.PadState, number | PlotService |

leaderstats (`Cash`, `Rebirths` NumberValues) are created and written by DataService only.

### 1e. Map contract (builder places these in the Studio place; PlotLayout is the only code that knows names)
- 6 plot Models tagged `Plot` with attribute `PlotId` 1..6, `ModelStreamingMode = Atomic`. Children: `Gate`
  (part), `Pads` (folder, one part per `PadId`), `Droppers` (folder, Models `1`..`10`, each with Attachment `Spout`),
  `Conveyor` (folder of Attachments `P1`..`Pn` in path order), `Seller` (part).
- 3 leaderboard boards tagged `Leaderboard` with attribute `Board` = `Rebirths` | `TotalCash` | `Donors`.
- Exact child names are finalised by world-programmer in PlotLayout and logged in `docs/asset-briefs/`.

## 2. Remotes
Matches `Remotes.Definitions` exactly (5 remotes, all RemoteEvents). Payload types are in `Contracts/Types.luau`.

| Name | Kind | Direction | Payload | Server validation | Rate limit | Owner module |
|---|---|---|---|---|---|---|
| RequestRebirth | RemoteEvent | Client -> Server | none (extra args ignored) | profile loaded; plot claimed; `Cash >= RebirthCost` computed on server; reuses `RebirthService.tryRebirth` | 1 per 2 s per player, excess dropped | Gameplay/RebirthService (handler); UI/HudController (sender) |
| ClaimDailyReward | RemoteEvent | Client -> Server | none (extra args ignored) | profile loaded; server `os.time()` is a new UTC day since `daily.lastClaimUnix`; reward computed on server | 1 per 2 s per player | Gameplay/DailyRewardService (handler); UI/DailyRewardController (sender) |
| SetDonorPrivacy | RemoteEvent | Client -> Server | `hidden: boolean` | `typeof(hidden) == "boolean"` else drop; profile loaded; no-op if unchanged | 1 per 1 s per player | Data/DataService (handler); UI/ShopController (sender) |
| Notify | RemoteEvent | Server -> Client | `T.NotifyPayload` | n/a (server builds text; never echoes client strings) | server sends <= 2 per s per player | UI/NotificationController (handler); fired by any server service |
| PlayEffect | RemoteEvent | Server -> Client | `effect: T.EffectId, payload: T.EffectPayload` | n/a (cosmetic only; client never sends back) | <= 5 per s per server; `FireAllClients` for plot effects | Effects/EffectsController (handler); fired by Gameplay services and MonetizationService |

Handler rules for every C->S remote: signature `function(player: Player, ...: any)`; type-check every argument
with `typeof`; reject NaN/inf numbers; per-player rate limit with `os.clock()` timestamps, cleared on
`PlayerRemoving`; never yield inside the handler before validation; never trust client-sent amounts, ids or prices.
`PlayEffect` effect ids: `PlotClaimed` {plotId, userId}, `Purchase` {plotId, padId}, `Rebirth` {plotId, userId},
`DailyReward` {amount} (to the claimer only), `Donation` {userId, tier} (tier 1..5 = Small..Mega; userId omitted if opted out).

## 3. Data schema and Data API (owned by systems-programmer)
**Store:** ProfileStore (section 4), store name `PlayerData_v1`, key `Player_<UserId>`. Session-locked.

### Profile schema v1 (`T.ProfileData`)
| Field | Type | Default | Since | Written by (through the Data API) |
|---|---|---|---|---|
| schemaVersion | number | 1 | v1 | DataService (migrations) |
| cash | number | 50 | v1 | `addCash` / `trySpendCash`, RebirthService (reset) |
| droppersOwned | number 1..10 | 1 | v1 | PurchaseService, RebirthService |
| upgrades.FasterGears / .SugarGlaze | number 0..3 | 0 / 0 | v1 | PurchaseService, RebirthService |
| rebirths | number | 0 | v1 | RebirthService |
| daily.streak / .lastClaimUnix | number | 0 / 0 | v1 | DailyRewardService |
| stats.totalCashEarned | number | 0 | v1 | DataService (`addCash` with reason Income or DailyReward) |
| stats.robuxDonated | number | 0 | v1 | MonetizationService |
| stats.firstJoinUnix / .playTimeSec | number | now / 0 | v1 | DataService |
| settings.hideFromDonorBoard | boolean | false | v1 | DataService (`SetDonorPrivacy`) |
| badges | { [BadgeKey]: boolean } | {} | v1 | BadgeAwardService |
| receipts | { string } (last 50 PurchaseIds) | {} | v1 | MonetizationService |

Rules: numbers are plain Luau numbers (doubles; exact to 2^53, enough for v1 rebirth costs). New fields are added
with defaults through `Profile:Reconcile()`; renames/removals bump `schemaVersion` with a migration in DataService.
Passes are never stored (checked live). Rebirth keeps rebirths, daily, stats, settings, badges, receipts.

### Data API (`src/server/Data/DataService.luau`)
```luau
DataService.ProfileLoaded: RBXScriptSignal    -- (player: Player, data: T.ProfileData)
DataService.ProfileReleasing: RBXScriptSignal -- (player: Player) just before the session ends
function DataService.isLoaded(player: Player): boolean
function DataService.getData(player: Player): T.ProfileData?       -- READ-ONLY for callers
function DataService.waitForData(player: Player, timeoutSec: number?): T.ProfileData? -- **yields**, default 30 s
function DataService.getCash(player: Player): number
function DataService.addCash(player: Player, amount: number, reason: T.CashReason): number -- amount > 0, finite; returns new cash
function DataService.trySpendCash(player: Player, amount: number, reason: T.CashReason): boolean
function DataService.update(player: Player, mutator: (data: T.ProfileData) -> ()): boolean
    -- runs mutator synchronously (it must not yield), then re-syncs DataService attributes and leaderstats;
    -- false if the profile is not loaded
```
Other modules never touch ProfileStore, DataStoreService for player data, or the profile table directly
except inside `update`. Saving: ProfileStore auto-save plus an explicit `Profile:Save()` every 60 s (GDD),
on leave (`Profile:EndSession()`), and on shutdown (ProfileStore handles `BindToClose`). If a profile cannot be
loaded (session lock or DataStore outage), DataService kicks the player with a friendly retry message.
Receipts: `ProcessReceipt` returns `PurchaseGranted` only after the PurchaseId is in `receipts` and the profile
is saved; otherwise `NotYetProcessed`. TODO(verify-api): confirm exact ProfileStore method names
(`StartSessionAsync`, `Reconcile`, `Save`, `EndSession`, `OnSessionEnd`) against the installed version in sprint 1.

Global leaderboards (LeaderboardService): OrderedDataStores `LB_Rebirths_v1`, `LB_TotalCash_v1`, `LB_Donors_v1`,
integer values (`math.floor`), written once per 60 s per player only if changed, top 50 read every 60 s.
Donors board shows **name and rank only**, never Robux amounts, and skips opted-out players (D-008; final
amount display is an owner decision).

## 4. Startup order and packages
### Server (`src/server/Main.server.luau`, unchanged)
1. `Remotes.setup()` creates `ReplicatedStorage.Remotes` with every remote.
2. Require direct-child modules of `Data`, then `World`, then `Gameplay`.
3. `Init()` on all, same order (local state, BindableEvents, no yields, no cross-service calls).
4. `Start()` on all via `task.spawn`: connect remotes, signals, `PlayerAdded`/`PlayerRemoving`, loops.
   Every `Start()` also handles players already in `Players:GetPlayers()`.

Player join: DataService loads the profile (yields) -> `ProfileLoaded`; PlotService waits for gate touch or
20 s auto-claim -> `PlotClaimed`; Gameplay, on `PlotClaimed`, calls `DataService.waitForData` then
`PlotService.setProgress` and `IncomeService.refresh`; MonetizationService checks passes after join -> `PassTierChanged`
-> `IncomeService.refresh`. Player leave: Gameplay drops per-player state, PlotService resets the plot,
DataService ends the session. Order of `PlayerRemoving` handlers does not matter: Cash lives in the profile at all times.

### Client (`src/client/Main.client.luau`, unchanged)
Require `UI` then `Effects`; `Init()` all, then `Start()` all. Controllers wait for `DataLoaded == true` before
showing Cash and handle plots streaming in/out (StreamingEnabled is on).

### Wally packages
| Package | Realm | Use | Why |
|---|---|---|---|
| ProfileStore (loleris) | server | DataService only | Session locking prevents item/cash duplication and lost saves when a player server-hops or a server crashes mid-save; handles retries, DataStore budget, auto-save and `BindToClose`. Writing that ourselves is days of risky work for a 3-week launch. |

Dependency line for `wally.toml` `[server-dependencies]` (installs to `ServerPackages`, already mapped in
`default.project.json`): `ProfileStore = "lm-loleris/profilestore@1.0.3"`.
TODO(verify-api): confirm scope/name/version with `wally search profilestore` before adding.
**Not added yet: sprint-1 integration ticket.** No other packages: the bootstrap replaces a framework (no Knit),
5 remotes need no networking library, signals use BindableEvent, validation uses `typeof`.

### Sprint-1 integration tickets (integration-programmer)
1. Add ProfileStore to `wally.toml`, run `wally install`, verify the API names flagged above.
2. `src/shared/Contracts/MonetizationConfig.luau`: pass ids/tiers/multipliers and donation product ids/tiers
   (ids filled in after the owner creates and approves them; read by MonetizationService and ShopController).
3. `src/shared/Contracts/NumberFormat.luau`: K/M/B/T formatter shared by UI and LeaderboardService.
4. `src/shared/Contracts/RateLimit.luau`: tiny per-player `os.clock()` limiter used by every C->S handler.

## 5. Performance budgets (target: low-end mobile, ~2 GB RAM phone, 6 players)
| Area | Budget |
|---|---|
| Client memory (Developer Console total) | <= 700 MB on mobile; place assets (meshes + textures) <= 150 MB |
| Parts in Workspace | hub <= 3,000; each plot <= 1,200 at full build (10 droppers); total <= 11,000 |
| Unique meshes / textures | <= 80 meshes; textures <= 512 px (1024 only for signage) |
| Candy visuals | <= 40 per plot, only plots within 200 studs; pooled, anchored, `CanCollide/CanTouch/CanQuery = false`, `CastShadow = false`; moved in one `RenderStepped`/`Heartbeat` loop with `workspace:BulkMoveTo` |
| Client frame time | Effects <= 2 ms/frame, UI <= 1 ms/frame on low-end mobile; no per-candy connections |
| Particles / lights / sounds | <= 200 particles alive; no dynamic lights on candy; <= 8 concurrent sounds |
| Server tick | one 1 Hz income loop for all players; server script time <= 5 % (6 players) |
| Remote traffic | C->S <= 1 msg/s avg per player; S->C <= 2 KB/s per player; attribute writes <= 3/s per player |
| DataStore | 1 save per player per 60 s + on leave; leaderboard writes <= 3 per player per 60 s; reads 3 per 60 s |
| Streaming | StreamingEnabled on; plots `Atomic`; client code never assumes a plot is streamed in |

qa measures these in `/sprint` builds with the Developer Console on the smallest test device.

## 6. Contract requests
Programmers add requests through their summary; team-lead routes them here. integration-programmer decides.

| # | From | Request | Status |
|---|---|---|---|
