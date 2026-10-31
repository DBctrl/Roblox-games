# Architecture: "Aura Up!" (working title) v1
_Owned by integration-programmer. Sections: see .claude/agents/integration-programmer.md. Version 1.1, 2026-10-31
(D-017, updated for GDD rev 1 / option A in D-023). Built from docs/gdd.md rev 1, approved by the owner (D-021).
Source of truth for code contracts: `src/shared/Contracts/Remotes.luau` and `src/shared/Contracts/Types.luau`.
Both must match this file. Applies lawyer rulings D-016 and D-019 (policy gate on Robux eggs only, next-tier-only
ladder, restricted receipts). Prices are still placeholders (gate 5): they live only in config (`EconomyConfig`,
`ProductCatalog`), so a price change does not change this contract._

## Toolchain (cloud session, sprint 1, D-022)
Binaries live outside the repo in `/home/user/.tools/bin` (git-ignored): StyLua 2.0.2, Selene 0.28.0, Rojo 7.4.4
(the same versions are pinned in `rokit.toml` for the Mac). They are not on `PATH`, so call them by absolute path.
Run from the repo root or your worktree root (the folder that holds `selene.toml`):
```
/home/user/.tools/bin/stylua src            # format (stylua --check src to verify only)
/home/user/.tools/bin/selene src            # lint; must print 0 errors, 0 warnings
/home/user/.tools/bin/rojo build default.project.json -o /tmp/build.rbxl
```
Selene's Roblox std is pre-generated at `~/.cache/selene/roblox.yml` (selene's own download fails behind the TLS
proxy). Do not delete it; do not commit a `roblox.yml`. The PostToolUse hook only runs the tools if they are on
`PATH`, so run the two lint commands yourself before each commit. `Packages`/`ServerPackages` are optional paths in
`default.project.json`, so `rojo build` works before `wally install`. No Studio, Studio MCP or wally in the cloud.

## 0. Ground rules
- **Server-authoritative everything.** MP, coins, the multiplier, boss wins, egg rolls, pity, duel scores, duel
  results and rewards are computed on the server only. The client sends **intents** (tap counts, "fight boss X",
  "hatch egg Y") and draws what the server tells it. The client never sends an amount, a price, a result or a roll.
- **Physical things are detected on the server.** The World 2 portal is a server `Touched` check and pod presence
  is a server zone check, so they need no remotes. Shop stands are `ProximityPrompt`s that only open UI (GDD 8b).
  **There are no purchase pads** (GDD 8b).
- **State reaches clients through attributes** (section 1d, one writer each), not remotes. Remotes are only for
  UI intents (C->S) and one-shot results/effects (S->C). **No RemoteFunctions in v1**: nothing waits on a client.
- **Folder boundaries.** Each programmer edits only their folders (CLAUDE.md). Modules may `require` (read) any
  public API listed here, never edit it. Shared cross-folder contracts live in `src/shared/Contracts` and change
  only through a Contract request (section 8).
- **`Init()` never yields and never calls another service.** Cross-service calls and signal connections happen in
  `Start()` or later. Every `Start()` also handles players already in `Players:GetPlayers()`.
- **Signals** are `BindableEvent`s owned by the emitting service, exposed as `RBXScriptSignal`. No signal library.
- **Only direct-child ModuleScripts are services.** Helpers go in a subfolder (e.g. `src/server/Gameplay/Util/`).
- **One balance file.** Every number in GDD 4-8 lives in `src/shared/Gameplay/EconomyConfig` (pure data and pure
  functions). Server and client read the same file, so the odds the UI shows are the odds the server rolls.

## 1. Module map
Path prefix: `ServerScriptService.Server` = `src/server`, `ReplicatedStorage.Shared` = `src/shared`,
`StarterPlayerScripts.Client` = `src/client`. `T.` = `Contracts/Types`. All functions are yield-free unless
marked **yields**. Every Gameplay entry point that takes a `Player` returns `(boolean, string?)` = ok, reason
when it can fail.

### 1a. Dependency direction (no cycles; arrows mean "may require")
```
Gameplay  --->  World  --->  Data  --->  (Packages, Contracts, shared config)
   |                          ^
   +--------------------------+
Inside Gameplay, layers (a module may require only lower layers):
  L0  ActivityService, MultiplierService
  L1  RankService, ShopService, PetService, BossService
  L2  TapService, RebirthService
  L3  IdleService, DuelService, QuestService, RewardService
Client: UI and Effects never require each other or any server module.
Shared: Contracts, EconomyConfig, MapLayout, EffectsConfig require nothing but each other (no Roblox services
        except in MapLayout, which reads CollectionService).
```
Upward calls are done by **inversion**, never by requiring up:
- Data -> Gameplay (receipt grants): Gameplay services call `MonetizationService.registerGrant(kind, fn)` in `Start()`.
- TapService -> DuelService (duel taps): DuelService calls `TapService.setTapSink(player, sink)` while a duel runs.
- Anything -> QuestService / TelemetryService: QuestService listens to the L1/L2 signals; Gameplay calls
  `TelemetryService` (Data layer) directly.

### 1b. Server services
| # | Module | Owner | Folder | Responsibility |
|---|---|---|---|---|
| 1 | DataService | systems | `src/server/Data` | ProfileStore sessions, Data API (section 3), data attributes, leaderstats, `SetSetting` handler |
| 2 | MonetizationService | systems | `src/server/Data` | The only `ProcessReceipt`, receipt dedupe, `RequestPurchase` gate + server-side prompt, entitlement attributes, grant registry |
| 3 | ComplianceService | systems | `src/server/Data` | PolicyService check per player, `PaidRandomAllowed` attribute (fail closed) |
| 4 | LeaderboardService | systems | `src/server/Data` | OrderedDataStores (Lifetime MP, Rebirths, weekly Duel Wins, Donors), hub boards + podium data |
| 5 | TelemetryService | systems | `src/server/Data` | Thin wrapper over Roblox `AnalyticsService`; funnel dedupe via `profile.milestones` (section 6) |
| 6 | ZoneService | world | `src/server/World` | Current world per player, portal, pod presence, stage/stand/ring lookup + distance checks, ring reservation, teleports |
| 7 | CharacterService | world | `src/server/World` | Single writer of Humanoid `WalkSpeed`/`JumpPower`; applies rank looks/fits (accessories); movement locks |
| 8 | ActivityService | gameplay | `src/server/Gameplay` | Per-player exclusive activity (Idle/BossFight/Hatching/Duel); `Activity` attribute |
| 9 | MultiplierService | gameplay | `src/server/Gameplay` | The multiplier pipeline (section 4a), timed boosts, coin multiplier (free Coin Snack only), ladder + boost grants |
| 10 | RankService | gameplay | `src/server/Gameplay` | Rank ladder from lifetime MP, rank-up moment, look id |
| 11 | ShopService | gameplay | `src/server/Gameplay` | `BuyTool`, `BuyPod` (coins only; no Robux path to tools or pods, GDD 8g) |
| 12 | PetService | gameplay | `src/server/Gameplay` | `HatchEgg` (coin eggs, open to all, D-021), Robux egg / fixed pet / Starter Pack grants, server roll + pity, inventory, `EquipPet`, `DeletePets` |
| 13 | BossService | gameplay | `src/server/Gameplay` | `RequestBossFight`, 3 s fight, coins, `FirstWin`, best-boss income |
| 14 | TapService | gameplay | `src/server/Gameplay` | `TapBatch`, tap token bucket, the only MP adder (`addMp`) |
| 15 | RebirthService | gameplay | `src/server/Gameplay` | `RequestRebirth`, atomic reset (coins only; no paid skip) |
| 16 | IdleService | gameplay | `src/server/Gameplay` | 1 Hz loop: pod MP/s, Auto-Tap, Auto-Mog |
| 17 | DuelService | gameplay | `src/server/Gameplay` | Duel state machine, challenges, anti-grief, scoring, rewards (section 4c) |
| 18 | QuestService | gameplay | `src/server/Gameplay` | Tutorial quest chain, `TutorialDone` (unlocks duels + Starter Pack pop-up timing) |
| 19 | RewardService | gameplay | `src/server/Gameplay` | Daily 7-day calendar, `ClaimDailyReward`, `RedeemCode` |

**Public APIs**
```luau
-- DataService: section 3.

-- MonetizationService
MonetizationService.EntitlementsChanged: RBXScriptSignal -- (player: Player)
function MonetizationService.registerGrant(kind: T.GrantKind,
	fn: (player: Player, key: T.ProductKey, data: T.ProfileData) -> boolean): ()
	-- fn mutates `data` synchronously (no yields, no other DataService calls); false = cannot grant now
function MonetizationService.getPaidTier(player: Player): number      -- 0..5 (0 = none, 5 = x32)
function MonetizationService.hasVip(player: Player): boolean
function MonetizationService.owns(player: Player, key: T.ProductKey): boolean -- permanent entitlements only

-- ComplianceService
function ComplianceService.paidRandomAllowed(player: Player): boolean -- false until checked (fail closed)

-- TelemetryService (never per tap; callers pass server-computed values only)
function TelemetryService.funnel(player: Player, step: T.FunnelStep): ()          -- deduped per profile
function TelemetryService.economy(player: Player, flow: "Source" | "Sink", amount: number,
	reason: T.CoinReason): ()
function TelemetryService.custom(player: Player, name: T.CustomEvent, value: number?): ()

-- ZoneService
ZoneService.PodChanged: RBXScriptSignal  -- (player: Player, podIndex: number) 0 = left all pods
ZoneService.WorldChanged: RBXScriptSignal -- (player: Player, worldId: T.WorldId)
function ZoneService.getWorld(player: Player): T.WorldId
function ZoneService.getPod(player: Player): number
function ZoneService.isNearBoss(player: Player, bossId: string): boolean      -- <= EconomyConfig.INTERACT_RANGE
function ZoneService.isNearEggStand(player: Player, eggId: T.EggId): boolean
function ZoneService.reserveRing(worldId: T.WorldId): number?                 -- ring index or nil if both busy
function ZoneService.releaseRing(worldId: T.WorldId, ringIndex: number): ()
function ZoneService.teleportToRing(player: Player, worldId: T.WorldId, ringIndex: number, side: 1 | 2): ()
function ZoneService.getRingKnockback(worldId: T.WorldId, ringIndex: number): Vector3 -- unit vector to foam pit
function ZoneService.teleportToWorld(player: Player, worldId: T.WorldId): boolean -- checks unlock

-- CharacterService
function CharacterService.setLook(player: Player, lookId: string): ()        -- respects ShowOwnLook setting
function CharacterService.setSpeedMultiplier(player: Player, mult: number): ()
function CharacterService.setMovementLocked(player: Player, reason: string, locked: boolean): () -- reason-keyed

-- ActivityService
function ActivityService.tryBegin(player: Player, activity: T.Activity): boolean -- false if not Idle
function ActivityService.finish(player: Player, activity: T.Activity): ()
function ActivityService.get(player: Player): T.Activity

-- MultiplierService (section 4a)
MultiplierService.Changed: RBXScriptSignal -- (player: Player, m: number)
function MultiplierService.getMpMultiplier(player: Player): number    -- M, clamped
function MultiplierService.getCoinMultiplier(player: Player): number
function MultiplierService.refresh(player: Player): ()
function MultiplierService.addBoost(player: Player, kind: T.BoostKind, seconds: number): () -- caps at 2 h

-- RankService
RankService.RankUp: RBXScriptSignal -- (player: Player, rank: number)
function RankService.onLifetimeMp(player: Player, lifetimeMp: number): () -- called by TapService only
function RankService.getRank(player: Player): number

-- ShopService
ShopService.ToolBought: RBXScriptSignal -- (player: Player, toolIndex: number)
ShopService.PodBought: RBXScriptSignal  -- (player: Player, podIndex: number)
function ShopService.tryBuyTool(player: Player, toolIndex: number): (boolean, string?)
function ShopService.tryBuyPod(player: Player, podIndex: number): (boolean, string?)
function ShopService.getToolPower(player: Player): number

-- PetService
PetService.Hatched: RBXScriptSignal -- (player: Player, eggId: T.EggId, results: { T.HatchedPet })
function PetService.tryHatch(player: Player, eggId: T.EggId, count: number): (boolean, string?) -- coin eggs
function PetService.grantEgg(player: Player, eggId: T.EggId, count: number): boolean -- Robux / daily, no cost
function PetService.getPetMultiplierSum(player: Player): number -- sum of equipped bonuses (before cap)
function PetService.freeSlots(player: Player): number -- inventory space left

-- BossService
BossService.BossWon: RBXScriptSignal -- (player: Player, bossId: string, coins: number, auto: boolean)
function BossService.tryFight(player: Player, bossId: string, auto: boolean): (boolean, string?)
function BossService.bestBeatable(player: Player): string? -- strongest boss in current world with MP >= need
function BossService.bestCoinsPerSec(player: Player): number -- for packs, daily, duel rewards

-- TapService
function TapService.addTaps(player: Player, count: number, source: "Manual" | "Auto"): number -- accepted
function TapService.addMp(player: Player, amount: number, source: T.MpSource): () -- the only MP writer
function TapService.setTapSink(player: Player, sink: ((accepted: number) -> ())?): ()

-- RebirthService
RebirthService.Rebirthed: RBXScriptSignal -- (player: Player, rebirths: number)
function RebirthService.tryRebirth(player: Player): (boolean, string?) -- rev 1: `skip` argument removed
function RebirthService.getCost(player: Player): number

-- IdleService: no public functions.
-- DuelService
function DuelService.isInDuel(player: Player): boolean
-- QuestService
QuestService.TutorialCompleted: RBXScriptSignal -- (player: Player)
function QuestService.isTutorialDone(player: Player): boolean
-- RewardService: no public functions.
-- LeaderboardService: no public functions.
```

### 1c. Shared modules
| # | Module | Owner | Folder | Contents |
|---|---|---|---|---|
| 20 | Contracts/Remotes | integration | `src/shared/Contracts` | Remote list + per-remote rate limits, `setup`, `get`, `getEvent`, `getFunction` |
| 21 | Contracts/Types | integration | `src/shared/Contracts` | Exported types, attribute/tag names, schema version |
| 22 | Gameplay/EconomyConfig | gameplay | `src/shared/Gameplay` | All GDD 4-7 numbers: tools, pods, bosses, rebirth, ranks, eggs (odds as integer weights summing to 10,000), pets, duel and tap caps, `M_CLAMP`, pure formula functions |
| 23 | World/MapLayout | world | `src/shared/World` | Tag/attribute accessors for builder's map (nil-safe for streaming) |
| 24 | Physics/EffectsConfig | physics | `src/shared/Physics` | Ragdoll impulse/duration, pool sizes, particle budgets, camera timings |
| 21a | Contracts/RateLimit | integration | `src/shared/Contracts` | Per-player, per-remote token bucket for every C->S handler (T-004) |
| 21b | Contracts/NumberFormat | integration | `src/shared/Contracts` | Pure display formatting: K/M/B/T/Qa, commas, countdowns, multipliers, egg odds (T-004) |

Sprint 3 adds `Contracts/ProductCatalog.luau` (T-069: ProductKey -> product id, grant kind, price label; ids filled
after the owner approves prices and creates the products).

```luau
-- Contracts/RateLimit (server). Limits come from Remotes.Definitions[name].rate/burst; over-limit calls are
-- dropped silently; per-player state is cleared on PlayerRemoving automatically.
function RateLimit.connect(name: Remotes.RemoteName, handler: (player: Player, ...any) -> ()): RBXScriptConnection
	-- preferred: OnServerEvent behind the bucket; the handler still validates every argument
function RateLimit.check(player: Player, name: Remotes.RemoteName): boolean -- first line of a hand-made handler
function RateLimit.clear(player: Player): ()
function RateLimit.newBucket(burst: number, now: number): RateLimit.Bucket  -- pure, for tests
function RateLimit.take(bucket: RateLimit.Bucket, rate: number, burst: number, now: number): boolean -- pure

-- Contracts/NumberFormat (pure; never returns "nan"/"inf"; truncates, never rounds up)
function NumberFormat.abbreviate(n: number, decimals: number?): string -- 1500 -> "1.5K", 1e18 -> "1000Qa"
function NumberFormat.commas(n: number): string        -- 1234567 -> "1,234,567"
function NumberFormat.duration(seconds: number): string -- 299 -> "4:59", 3903 -> "1:05:03"
function NumberFormat.multiplier(m: number): string    -- 1.25 -> "x1.25", 12500 -> "x12.5K"
function NumberFormat.oddsPercent(weight: number): string -- weight out of 10,000: 50 -> "0.5%"
```
TapBatch keeps its own per-tap bucket in TapService (taps per second); RateLimit only limits messages per second.

```luau
-- EconomyConfig surface other folders rely on (gameplay-programmer fills the values from GDD 4-7)
EconomyConfig.TAP_CAP_PER_SEC: number          -- 12 (manual + auto, PvE)
EconomyConfig.DUEL_TAP_CAP_PER_SEC: number     -- 10
EconomyConfig.M_CLAMP: number                  -- 10000 (v1; raised per world in later updates)
EconomyConfig.PET_MULT_CAP: number             -- 25
EconomyConfig.INVENTORY_CAP: number            -- 60
EconomyConfig.INTERACT_RANGE: number           -- 20 studs (boss stage, egg stand)
EconomyConfig.TOOLS / PODS / BOSSES / RANKS / EGGS / PETS -- arrays/maps, GDD tables
function EconomyConfig.rebirthCost(n: number): number            -- 15000 x 3^(n-1)
function EconomyConfig.rebirthMult(rebirths: number): number     -- 1 + 0.5 x rebirths
function EconomyConfig.coinRebirthMult(rebirths: number): number -- 1 + 0.1 x rebirths
function EconomyConfig.paidTierMult(tier: number): number        -- 1, 2, 4, 8, 16, 32
function EconomyConfig.petSlots(rebirths: number, vip: boolean): number -- 3, +1 R3, +1 R8, +1 VIP
function EconomyConfig.duelScore(taps: number, ownRank: number, oppRank: number): number
function EconomyConfig.validate(): () -- asserts every egg's weights sum to 10000; qa runs it in tests
```

### 1d. Client controllers
| # | Controller | Owner | Folder | Responsibility |
|---|---|---|---|---|
| 25 | HudController | systems | `src/client/UI` | MP/coins/rank meters, boss "Need X MP" button state + MOG button (fires `RequestBossFight`), quest arrow, rebirth button, shop buttons hidden until `FirstWin` |
| 26 | TapController | systems | `src/client/UI` | Tap capture (touch/click not over GUI), local cap 12/s, sends `TapBatch` every 0.5 s; local "+N" from `MpPerTap` |
| 27 | ShopController | systems | `src/client/UI` | Tools, pods, Robux shop (fires `BuyTool`, `BuyPod`, `RequestPurchase`); shows only ladder tier `PaidTier + 1`, with "Does not stack: the highest tier you own applies" (D-008, D-016 #8) |
| 28 | EggController | systems | `src/client/UI` | Egg UI with exact odds, bonuses, "you own" ticks and pity counter before every purchase; hides Robux eggs when `PaidRandomAllowed` is false; `HatchEgg`, `HatchResult` |
| 29 | PetsController | systems | `src/client/UI` | Inventory (60), equip/unequip/equip best (`EquipPet`), multi-delete (`DeletePets`) |
| 30 | DuelController | systems | `src/client/UI` | Challenge button on players, accept/decline, countdown, tap-off HUD, result, rematch, block (`DuelChallenge`, `DuelRespond`, `DuelRematch`, `SetDuelBlock`, `DuelState`) |
| 31 | RewardsController | systems | `src/client/UI` | Daily calendar (`ClaimDailyReward`), codes box (`RedeemCode`) |
| 32 | SettingsController | systems | `src/client/UI` | Toggles (`SetSetting`) |
| 33 | NotificationController | systems | `src/client/UI` | `Notify` toasts (max 3) and server banners |
| 34 | EffectsController | physics | `src/client/Effects` | `PlayEffect` dispatch: tap sparkles (pooled), coin bursts, boss pose-off + boss ragdoll (local clone), purchase/donation effects |
| 35 | RagdollController | physics | `src/client/Effects` | Local player's own duel knockback ragdoll (2.5 s), only when the server names the local user |
| 36 | PetFollowController | physics | `src/client/Effects` | Renders every nearby player's equipped pets from `EquippedPets` (client-only models, float follow) |
| 37 | CinematicController | physics | `src/client/Effects` | Spawn camera pan, rank-up orbit/spotlight, hatch animation (skippable) |

Client controllers have no public functions. They read attributes, shared config and the remotes below.

### 1e. Attribute contract (state replication; one writer each; names in `Types.PlayerAttr`)
All on the `Player` instance unless stated. Writers flush changes at most **5 Hz** per player (MP and coins are
coalesced), so attribute traffic stays inside the budget in section 7.
| Attribute | Type | Writer |
|---|---|---|
| DataLoaded, Coins, Mp, LifetimeMp, Rebirths | boolean, number x4 | DataService |
| SettingDuelRequests, SettingShowOwnLook, SettingAutoDeleteCommons, SettingHideFromDonorBoard, SettingAutoTap, SettingAutoMog | boolean | DataService |
| PaidTier (0..5), Vip, AutoClickerOwned, StarterPackOwned | number, boolean x3 | MonetizationService |
| PaidRandomAllowed | boolean (false until checked) | ComplianceService |
| WorldId (1/2), World2Unlocked, CurrentPod (0 = none) | number, boolean, number | ZoneService |
| Activity | `T.Activity` | ActivityService |
| Multiplier, CoinMultiplier, HypeEndsAt, CoinSnackEndsAt (free-only boost), SpeedEndsAt | number (EndsAt = `workspace:GetServerTimeNow()` time, 0 = off) | MultiplierService |
| Rank, LookId | number, string | RankService |
| ToolIndex, PodsMask (bit i = pod i owned) | number | ShopService |
| EquippedPets (comma list of pet ids, for rendering), PetCount, PetSlots, PityStarEgg, PityGalaxyEgg | string, number x4 | PetService |
| FirstWin, BestCoinsPerSec | boolean, number | BossService |
| MpPerTap | number (ToolPower x M) | TapService |
| RebirthCost | number | RebirthService |
| IdleMpPerSec, AutoTapRate, AutoMogUnlocked | number, number, boolean | IdleService |
| InDuel, DuelWinsWeek | boolean, number | DuelService |
| QuestStep, TutorialDone | number, boolean | QuestService |
| DailyStreak, DailyClaimable, DailyNextClaimUnix | number, boolean, number | RewardService |

leaderstats (`Rank`, `Rebirths` IntValues) are created and written by DataService only (from profile on update).
Humanoid `WalkSpeed`/`JumpPower` are written by CharacterService only. Boss/pod/ring map parts carry builder
attributes only (section 1f); no code writes map attributes.

### 1f. Map contract (builder places these; MapLayout is the only code that knows names)
| Tag | Attributes | Use |
|---|---|---|
| `BossStage` | `BossId` (string), `WorldId` | stage anchor part + boss model (`ModelStreamingMode = Atomic`) |
| `Pod` | `PodIndex` 1..7, `WorldId` | pod zone part (non-collide box), presence checked on server |
| `EggStand` | `EggId`, `WorldId` | ProximityPrompt opens egg UI (no purchase prompt) |
| `ShopStand` | `Shop` = `Tools` / `Robux`, `WorldId` | ProximityPrompt opens shop UI |
| `MogRing` | `RingIndex` 1..2, `WorldId`; children `Side1`, `Side2`, `Pit` (parts) | duel arenas |
| `Portal` | `ToWorldId` | world travel (server `Touched`) |
| `Spawn` | `WorldId` | world spawn |
| `Leaderboard` | `Board` = `LifetimeMp` / `Rebirths` / `DuelWinsWeek` / `Donors` | hub boards |
| `Podium` | `Place` 1..3 | top-3 Lifetime MP looks |
Look/pet/fit templates: builder puts them in `ReplicatedStorage.Assets.Pets` and `ServerStorage.Assets.Looks`
(models named by pet id / look id). Logged in docs/asset-briefs/asset-log.md.

## 2. Remotes
Matches `Remotes.Definitions` exactly: **20 RemoteEvents (16 C->S, 4 S->C), 0 RemoteFunctions.** Payload types
are in `Contracts/Types.luau`. Rate limits are token buckets (`rate` per second, `burst`) per player per remote;
excess calls are **dropped silently** (no error reply, so spam earns nothing).

**Handler rules for every C->S remote:** signature `function(player: Player, ...: any)`; `typeof`-check every
argument and drop on mismatch; numbers must be finite (`x == x` and `math.abs(x) ~= math.huge`) and integers
where stated; strings length-capped before any other use; rate limit before any work (`RateLimit.connect`, section 1c); profile must be loaded
(`DataLoaded`); never yield before validation; never trust client ids, amounts or prices; rate-limit state is
cleared on `PlayerRemoving`.

| # | Name | Dir | Payload | Server validation | Rate (per s / burst) | Handler (sender) |
|---|---|---|---|---|---|---|
| 1 | TapBatch | C->S | `count: number` | integer 1..`TAP_BATCH_MAX` (30); token bucket at `TAP_CAP_PER_SEC` (12) minus the player's `AutoTapRate`, burst 1 s; in a duel the tap sink applies the duel clamp (section 4c); excess taps dropped | 4 / 4 | Gameplay/TapService (UI/TapController) |
| 2 | RequestBossFight | C->S | `bossId: string` | len <= 32; id in `EconomyConfig.BOSSES`; boss `WorldId` == player `WorldId`; `ZoneService.isNearBoss`; `Mp >= need`; `ActivityService.tryBegin("BossFight")`; 4 s cycle (fight 3 s, then 1 s); after 3 s re-check player still present, then award | 1 / 2 | Gameplay/BossService (UI/HudController) |
| 3 | BuyTool | C->S | `toolIndex: number` | integer; `== ToolIndex + 1`; tool's world unlocked; `trySpendCoins(cost)` | 2 / 3 | Gameplay/ShopService (UI/ShopController) |
| 4 | BuyPod | C->S | `podIndex: number` | integer 1..#PODS; not owned; pod's world unlocked; `trySpendCoins(cost)` | 2 / 3 | Gameplay/ShopService (UI/ShopController) |
| 5 | RequestRebirth | C->S | none (extra args ignored) | `Coins >= cost` computed on server; not in duel; atomic reset in one `DataService.update` | 0.5 / 1 | Gameplay/RebirthService (UI/HudController) |
| 6 | HatchEgg | C->S | `eggId: string, count: number` | eggId in `EGGS` and **coin** egg (Robux eggs only via `RequestPurchase`); count is 1, or 3 with `Rebirths >= 2`; egg world unlocked; `isNearEggStand`; `freeSlots >= count` (counting auto-delete); `ActivityService.tryBegin("Hatching")` (released after 1 s server-side; the 2 s animation is client-only and skippable); `trySpendCoins(price x count)`; roll on server | 1 / 2 | Gameplay/PetService (UI/EggController) |
| 7 | EquipPet | C->S | `petUid: string, equip: boolean` | len <= 12; uid in player's inventory; equip needs a free slot (`PetSlots`); no-op if unchanged | 8 / 10 | Gameplay/PetService (UI/PetsController) |
| 8 | DeletePets | C->S | `petUids: { string }` | array, 1..60 entries, each len <= 12, no duplicates; all owned; equipped pets are unequipped first | 1 / 2 | Gameplay/PetService (UI/PetsController) |
| 9 | DuelChallenge | C->S | `targetUserId: number` | integer; target in this server and != self; both `TutorialDone`; target `SettingDuelRequests`; target has not blocked sender (session); sender not auto-muted by target; both `Activity == Idle` and not `InDuel`; sender has no pending outgoing; 15 s cooldown per target; ring free | 0.5 / 1 | Gameplay/DuelService (UI/DuelController) |
| 10 | DuelRespond | C->S | `challengerUserId: number, accept: boolean` | integer + boolean; a pending challenge from that user to this player exists and is < 10 s old; on accept re-run every challenge check | 1 / 2 | Gameplay/DuelService (UI/DuelController) |
| 11 | DuelRematch | C->S | `accept: boolean` | boolean; player's last duel ended < 10 s ago; opponent still present; both accept -> new duel, same ring | 1 / 2 | Gameplay/DuelService (UI/DuelController) |
| 12 | SetDuelBlock | C->S | `targetUserId: number, blocked: boolean` | integer + boolean; target != self; session-only list, max 50 entries | 1 / 3 | Gameplay/DuelService (UI/DuelController) |
| 13 | RequestPurchase | C->S | `productKey: string` | len <= 24; key in `ProductCatalog` (23 keys); `FirstWin` (GDD 8a, all products); Robux eggs need `PaidRandomAllowed` and `freeSlots >= count`; fixed pets and Starter Pack need `freeSlots >= 1`; ladder tier `== PaidTier + 1` only (D-016 #8); permanent items (AutoClicker, Vip, fits) not owned; Starter Pack once; Hype Snack / Speed Sneakers refused when the 2 h cap would be exceeded (GDD 8h); tips always allowed. This is a **prompt** gate only (UX, D-016 #9); then server calls `MarketplaceService:PromptProductPurchase(player, id)` | 0.5 / 2 | Data/MonetizationService (UI/ShopController, EggController) |
| 14 | ClaimDailyReward | C->S | none | server UTC day > `daily.lastClaimDay`; streak resets if a day was missed; reward computed on server | 0.5 / 1 | Gameplay/RewardService (UI/RewardsController) |
| 15 | RedeemCode | C->S | `code: string` | len 1..20, `^[%w]+$`, upper-cased; code in RewardService's server-only list and active; not redeemed before (`profile.codes`); 10 wrong codes in 10 min -> 10 min lockout | 0.33 / 2 | Gameplay/RewardService (UI/RewardsController) |
| 16 | SetSetting | C->S | `key: string, value: boolean` | key in `T.SettingKey`; boolean; `AutoTap` needs Auto-Tap unlocked or owned, `AutoMog` needs it unlocked; no-op if unchanged | 2 / 5 | Data/DataService (UI/SettingsController) |
| 17 | Notify | S->C | `T.NotifyPayload` | n/a (server builds text, never echoes client strings) | server sends <= 2/s per player; banners `FireAllClients` <= 1/s per server | UI/NotificationController (any server service) |
| 18 | PlayEffect | S->C | `effect: T.EffectId, payload: T.EffectPayload` | n/a (cosmetic) | <= 10/s per server; boss wins only to players in the same world | Effects/EffectsController (Gameplay services, MonetizationService) |
| 19 | HatchResult | S->C | `T.HatchResultPayload` | n/a | 1 per hatch, to the hatcher only | UI/EggController + Effects/CinematicController (PetService) |
| 20 | DuelState | S->C | `T.DuelStatePayload` | n/a | on phase change only, to the 1-2 duelists | UI/DuelController + Effects/RagdollController (DuelService) |

`PlayEffect` ids: `BossWin` {userId, bossId, amount}, `RankUp` {userId, rank}, `Rebirth` {userId, rebirths},
`DuelKnockback` {userId, direction} (loser only), `DuelBounce` {userId} (draw), `Purchase` {userId, productKey},
`Donation` {userId?, tier} (userId omitted if opted out), `DailyReward` {amount}.

## 3. Data schema and Data API (owned by systems-programmer)
**Store:** ProfileStore (session-locked), store name `AuraUp_PlayerData_v1`, key `Player_<UserId>`.
If a profile cannot be loaded (session lock held elsewhere or a DataStore outage), the player is kicked with a
friendly "please rejoin" message. Nothing else touches DataStoreService for player data.

### 3a. Profile schema v1 (`T.ProfileData`)
| Field | Type | Default | Reset on rebirth | Written by (through `DataService.update`) |
|---|---|---|---|---|
| schemaVersion | number | 1 | no | DataService (migrations) |
| coins | number | 0 | yes | addCoins / trySpendCoins |
| mp / lifetimeMp | number | 0 / 0 | mp yes / lifetime no | TapService |
| rebirths | number | 0 | no | RebirthService |
| toolIndex | number 1..12 | 1 | yes (to 1) | ShopService, RebirthService |
| podsMask | number (bits 1..7) | 0 | no | ShopService |
| world2Unlocked | boolean | false | no | ZoneService (Rebirth 3 only) |
| firstWin | boolean | false | no | BossService |
| rank | number 1..12 | 1 | no | RankService |
| quest | { step: number, done: boolean } | {1, false} | no | QuestService |
| pets | { inventory: { [uid]: { id: string } }, equipped: { string }, nextUid: number } | empty, 1 | no | PetService |
| pity | { [EggId]: number } | {} | no | PetService (Robux eggs only) |
| entitlements | { paidTier: number, vip, autoClicker, starterPack: boolean, cosmetics: { [string]: boolean } } | 0 / false | no | MonetizationService (flags); `paidTier` by MultiplierService's PaidTier grant; `starterPack` + `cosmetics.RookieShades` by PetService's StarterPack grant |
| boosts | { hypeSec, coinSec, speedSec: number } (remaining seconds, tick only while online) | 0 | no | MultiplierService |
| daily | { streak: number, lastClaimDay: number (UTC days since epoch) } | 0, 0 | no | RewardService |
| codes | { [string]: boolean } | {} | no | RewardService |
| duel | { weekId: number, weekWins: number, rewardLog: { { t: number, opp: number } } (last 1 h) } | 0, 0, {} | no | DuelService |
| settings | { duelRequests, showOwnLook, autoDeleteCommons, hideFromDonorBoard, autoTap, autoMog: boolean } | true, true, false, false, true, true | no | DataService (`SetSetting`) |
| stats | { firstJoinUnix, playTimeSec, totalCoinsEarned, bossWins, duelWins, duelsPlayed, robuxDonated: number } | now, 0... | no | owners of each stat |
| milestones | { [FunnelStep]: boolean } | {} | no | TelemetryService (funnel dedupe) |
| receipts | { string } (last 100 PurchaseIds, FIFO) | {} | no | MonetizationService |

Rules: plain doubles (exact to 2^53; v1 max values ~1e10). New fields are added with defaults through
`Profile:Reconcile()`; renames/removals bump `schemaVersion` with a migration step in DataService. Duel
`settings.duelRequests` is forced off for the client until `quest.done` (GDD 6).

### 3b. Data API (`src/server/Data/DataService.luau`)
```luau
DataService.ProfileLoaded: RBXScriptSignal    -- (player: Player, data: T.ProfileData)
DataService.ProfileReleasing: RBXScriptSignal -- (player: Player) just before the session ends
function DataService.isLoaded(player: Player): boolean
function DataService.getData(player: Player): T.ProfileData?           -- READ-ONLY for callers
function DataService.waitForData(player: Player, timeoutSec: number?): T.ProfileData? -- **yields**, default 30 s
function DataService.addCoins(player: Player, amount: number, reason: T.CoinReason): number -- finite, > 0
function DataService.trySpendCoins(player: Player, amount: number, reason: T.CoinReason): boolean
function DataService.update(player: Player, mutator: (data: T.ProfileData) -> ()): boolean
	-- mutator runs synchronously (must not yield); then DataService marks its attributes dirty (5 Hz flush)
function DataService.getSetting(player: Player, key: T.SettingKey): boolean
```
Saving: ProfileStore auto-save, on leave (`EndSession`), and on shutdown (ProfileStore's `BindToClose`).

### 3c. ProcessReceipt and receipt-id dedupe (MonetizationService, the only assigner of `ProcessReceipt`)
1. Find the player by `receiptInfo.PlayerId`; if absent or profile not loaded -> `NotYetProcessed` (Roblox retries).
2. If `PurchaseId` is in `profile.receipts` -> `PurchaseGranted` (already granted; idempotent).
3. Look up the ProductKey by `ProductId`; unknown id -> log + `NotYetProcessed`.
4. In **one** `DataService.update`: call the registered grant fn for the key's `GrantKind` with that update's
   `data` table, then append the PurchaseId (trim to 100). If the grant returns false, nothing is recorded and the
   answer is `NotYetProcessed`. After the update, fire `EntitlementsChanged` so services refresh attributes.
5. Wait for the profile save that contains that PurchaseId, then return `PurchaseGranted`. If the session ends
   first -> `NotYetProcessed`.
Every valid paid receipt is delivered (D-016 #9): the FirstWin rule gates prompts, never receipts. A Robux-egg
receipt for a player whose `PaidRandomAllowed` is false grants the egg's **disclosed non-random outcome**
(`EconomyConfig.EGGS[eggId].restrictedGrant`, a fixed pet shown in the product description), never a random roll
and never nothing (D-016 #4). No product bundles an egg (D-016 #5).
`TODO(verify-api)`: exact ProfileStore names (`ProfileStore.New`, `StartSessionAsync`, `Reconcile`, `Save`,
`EndSession`, `OnSave`/`OnAfterSave`, `OnSessionEnd`) against the installed version in sprint 1.

### 3d. Global leaderboards (LeaderboardService)
OrderedDataStores `LB_LifetimeMp_v1`, `LB_Rebirths_v1`, `LB_DuelWins_w<weekId>` (weekId = Saturday 00:00 UTC
weeks), `LB_Donors_v1`. Integer values (`math.floor`), written once per 60 s per player only if changed; top 50
read every 120 s. Donors board shows **names and rank only**, skips opted-out players (D-008).

## 4. Authority models
### 4a. Multiplier pipeline (MultiplierService, server-only)
```
PetMult     = min(PET_MULT_CAP (25), 1 + PetService.getPetMultiplierSum(player))
RebirthMult = EconomyConfig.rebirthMult(rebirths)                 -- 1 + 0.5 x R
PaidTier    = EconomyConfig.paidTierMult(highest owned tier)      -- x1/2/4/8/16/32, never stacked
Vip         = 1.25 if owned else 1
Boost       = 2 while boosts.hypeSec > 0 else 1
M           = clamp(PetMult x RebirthMult x PaidTier x Vip x Boost, 1, M_CLAMP (10,000))   -- NaN -> 1
MP per tap  = ToolPower x M            MP/s in pod = PodRate x M
Coins/win   = BossCoins x coinRebirthMult(R) x (2 if coinSec > 0)  -- pets and paid tiers never touch coins
```
Recomputed only on events (pet equip/delete, rebirth, `EntitlementsChanged`, boost start/end), never per tap; the
cached value is used by TapService/IdleService. Duels never read M (section 4c). The client sees `Multiplier` for
display only and never sends it.

### 4b. Egg/pet roll (PetService, server-only)
- Odds come from `EconomyConfig.EGGS[eggId].pets` as integer weights summing to 10,000 (0.5% = 50). The UI renders
  the same table as percentages. `EconomyConfig.validate()` asserts the sums at server start and in qa tests.
- One server `Random.new()` (unseeded = engine seed) owned by PetService; the client never sees or sends a seed.
- **Pity (Robux eggs only):** `pity[eggId]` counts hatches since the last Legendary-or-better. On the 10th
  (`pity == 9` before rolling) with no hit, the roll is forced to the Legendary/Mythic subset weighted 90/10. Any
  Legendary+ resets to 0. A 3-pack counts as 3 hatches in order. Coin eggs have no pity.
- Grants are atomic: cost, roll, inventory insert and pity update in one `DataService.update`. Auto-delete
  Commons (setting) applies after the roll; results report `autoDeleted = true`.
- Inventory cap 60: coin hatches are rejected before charging; Robux eggs are blocked at `RequestPurchase` when
  space is short; a receipt that still arrives full may exceed the cap by up to 6 (hard cap 66) so no paid pet is lost.
- Daily Day-4 free hatch uses `grantEgg` (coin egg of the best unlocked world).

### 4c. PvP duel authority (DuelService)
Server state machine per duel: `Pending (10 s) -> Countdown (3 s) -> Active (8 s) -> Result (2.5 s) -> Rematch
window (10 s) -> Ended`. Phase times are sent as `workspace:GetServerTimeNow()` timestamps in `DuelState`, so both
clients show the same clock.
- **Start:** challenge checks in section 2 #9; on accept, `ZoneService.reserveRing` (challenger's world if the
  target has it unlocked, else World 1), `ActivityService.tryBegin("Duel")` for both (atomic: roll back if either
  fails), teleport, `CharacterService.setMovementLocked(.., "Duel", true)`. Auto-Tap and Auto-Mog pause for duelists.
- **Taps:** `TapService.setTapSink` routes the duelist's `TapBatch` to DuelService. Accepted = `min(count,
  DUEL_TAP_CAP_PER_SEC x (now - lastAccepted))`, counted only for batches received in `[activeStart, activeEnd +
  0.5 s grace]`, and the total is capped at `10 x 8 = 80`. No PvE MP is earned from duel taps.
- **Score:** `EconomyConfig.duelScore(taps, ownRank, oppRank)` = taps x (1 + 0.03 x min(ownRank, oppRank + 2)).
  Pets, PaidTier, VIP, boosts and auto-tap are never read. Equal scores = draw.
- **Result:** server picks the winner, sends `DuelState` Result, fires `PlayEffect DuelKnockback` with the ring's
  pit direction. The loser's own client applies the ragdoll (it owns its character's physics), and CharacterService
  keeps the movement lock for 2.5 s. The server never applies forces outside the ring and only to the two duelists.
- **Rewards (server only):** +1 week win and `120 x BossService.bestCoinsPerSec(winner)` coins, only if the
  winner's `duel.rewardLog` has < 5 entries in the last hour and < 2 vs this opponent in the last 15 min. Losers
  lose nothing.
- **Anti-grief:** 1 pending outgoing challenge; 15 s cooldown per target; 3 declines in a row from the same
  target -> challenger muted for that target for 10 min; session block list; Pending auto-declines at 10 s.
- **Forfeit:** leaving, character death/removal, or teleport out = forfeit, no reward to anyone; ring released.
- **Rematch:** both `DuelRematch(true)` within 10 s -> new Countdown in the same ring (ring kept reserved).

### 4d. PolicyService gate for Robux eggs (ComplianceService)
- Called on the **server** (works for any player there; on the client only for LocalPlayer, confirmed by lawyer
  from Roblox creator-docs, D-016 #2). Result cached per player; the attribute is for UI only.
- On join (in `task.spawn`), `pcall(PolicyService.GetPolicyInfoForPlayerAsync, PolicyService, player)`, up to 3
  tries with 2/4/8 s backoff. `PaidRandomAllowed = not info.ArePaidRandomItemsRestricted`. Any failure ->
  `false` (**fail closed**: Robux eggs hidden and unsellable).
- Server gate: `RequestPurchase` rejects `StarEgg1/3`, `GalaxyEgg1/3` when not allowed. Client gate: EggController
  hides Robux egg stands/UI from the attribute (cosmetic; the server gate is the real one).
- **Coin eggs: B-1 resolved, option A (approved by owner, D-021; lawyer D-019 #1).** Robux never buys coins, so
  coin eggs are unpaid random items and are **open to every player, with no policy gate**. The D-017 default coin-egg
  gate is removed: `EconomyConfig.COIN_EGGS_POLICY_GATED = false` (default), and T-029 removes the gate code from
  PetService. `HatchEgg` never reads `PaidRandomAllowed`. Robux eggs stay gated as above.
  - **Policy default:** Robux eggs fail closed (hidden and unsellable until `PaidRandomAllowed` is true); coin eggs,
    the Day-4 free hatch and event eggs are ungated.
  - **Under A (current):** 23 products, no coin product of any kind (section 4e). Any future product, bundle or perk
    that grants, multiplies or discounts coins, or grants a coin-shop item, reopens B-1 (D-019 #1).
  - **Under B (not chosen):** `COIN_EGGS_POLICY_GATED = true`, `HatchEgg` also needs `PaidRandomAllowed`, and
    restricted players need a non-random path (one new remote, e.g. `BuyPetDirect`, via a Contract request).
- Pity UI (D-016 #3): when `Pity<Egg> == 9`, EggController shows the real next-hatch odds (Legendary 90 / Mythic
  10) and the pity rule in words; the counter is saved in `profile.pity`.
- Group Crew Cap (D-016 #6, owner decision): if approved, a server `IsInGroup` check at join grants a cosmetic only;
  no remote and no gameplay effect.

### 4e. Purchase prompts and the FirstWin gate (MonetizationService)
Every prompt is server-initiated after `RequestPurchase` validation, so the FirstWin rule (GDD 8a) cannot be
bypassed by a modified client. The client never calls `PromptProductPurchase`. All 23 GDD rev 1 products are developer
products (`T.ProductKey`, listed in `Types.ProductKeys`); permanent ones are entitlements in the profile, re-applied on join.

**Product -> grant kind -> registering service (option A, D-021).** Grant fns mutate only the `data` table they are
handed, synchronously; services refresh their attributes on `EntitlementsChanged`.
| Products | GrantKind | Registered by | What the grant writes |
|---|---|---|---|
| MpX2, MpX4, MpX8, MpX16, MpX32 | PaidTier | MultiplierService | `entitlements.paidTier` = next tier. A receipt that is not for the next tier grants Hype Snack time (10 min per 2 R$, cap bypassed, logged) per D-019 #3; that fallback waits for the owner price review (D-021 #3) |
| HypeSnack, SpeedSneakers | Boost | MultiplierService | `boosts.hypeSec` +600 / `boosts.speedSec` +1800; time past the 2 h cap is added, never dropped (D-019 #4) |
| AutoClicker, Vip, GoldenGlowFit, NeonIconFit | Entitlement | MonetizationService | `entitlements.autoClicker` / `vip` / `cosmetics[key]` (Vip also sets `cosmetics.VipSparkleAura`) |
| RingLightRetriever, NeonPup | FixedPet | PetService | one copy of that pet into `pets.inventory` (may exceed 60 by up to 6) |
| StarterPack | StarterPack | PetService | Sparkle Pup into inventory + `boosts.hypeSec` +1800 + `cosmetics.RookieShades` + `entitlements.starterPack`. **No coins, no pod, no egg** |
| StarEgg1/3, GalaxyEgg1/3 | RobuxEgg | PetService | server roll + pity; restricted players get `restrictedGrant` (Starlight Corgi / Nebula Fox, x3 for a 3-pack) |
| Tip5, Tip25, Tip100, Tip500, Tip1000 | Donation | MonetizationService | `stats.robuxDonated`, banner + name-tag colour only |

VIP's daily perk (+10 min Hype Snack per daily claim) is applied by RewardService at claim time, not by a grant.
No grant may touch `coins`, `toolIndex`, `podsMask`, `rebirths`, `world2Unlocked` or call a coin-egg hatch; qa's GDD 8g
test walks every grant fn and fails if one does. Removed in rev 1 (never re-add without reopening B-1): Coin Pouch /
Bag / Vault, paid Coin Snack, pod unlocks 2-7, Skip Rebirth, Skip to World 2, Auto-Mog Early.

## 5. Analytics events (TelemetryService)
`TODO(verify-api)`: confirm the Roblox `AnalyticsService` method names and parameters (`LogOnboardingFunnelStepEvent`,
`LogFunnelStepEvent`, `LogEconomyEvent`, `LogCustomEvent`, `LogProgressionEvent`) and their limits in sprint 1.
| Event | Kind | When | Value |
|---|---|---|---|
| Spawn, FirstTap, FirstWin, FirstUpgrade, FirstPod, FirstRankUp, FirstEgg, TutorialDone, FirstRebirth | onboarding funnel, once per profile (`milestones`) | the first time it happens | seconds since `firstJoinUnix` (also logged as custom `TimeTo<Step>`) |
| Coins source | economy | BossWin, DuelReward, Daily, Code (never a Robux source, GDD 8g) | amount |
| Coins sink | economy | Tool, Pod, Egg, Rebirth | amount |
| Purchase | custom | each granted receipt (after dedupe) | Robux price; product key as event name suffix |
| DuelPlayed / DuelWon / DuelDraw / DuelForfeit | custom | duel end | duel seconds |
| SessionLength | custom | `PlayerRemoving` | seconds |
| RankUp / Rebirth | progression | each | new rank / rebirth count |
Never per tap, never more than 1 event per 5 s average per player.

## 6. Startup order and packages
### Server (`src/server/Main.server.luau`, unchanged)
1. `Remotes.setup()` creates `ReplicatedStorage.Remotes` with every remote.
2. Require direct-child modules of `Data`, then `World`, then `Gameplay`.
3. `Init()` on all, same order (local state, BindableEvents, no yields, no cross-service calls).
4. `Start()` on all via `task.spawn`: grants registered, remotes and signals connected, loops started.
Player join: DataService loads (yields) -> `ProfileLoaded` -> MonetizationService applies entitlements,
ComplianceService checks policy, ZoneService sets world, Gameplay services compute their attributes,
MultiplierService refreshes. Every handler checks `DataLoaded` first, so early remotes are dropped.
Player leave: Gameplay drops per-player state (DuelService forfeits, rings released), DataService ends the session.

### Client (`src/client/Main.client.luau`, unchanged)
Require `UI` then `Effects`; `Init()` all, then `Start()` all. Controllers wait for `DataLoaded == true` and handle
map parts streaming in/out (StreamingEnabled is on).

### Wally packages
| Package | Realm | Use | Why |
|---|---|---|---|
| ProfileStore (loleris) | server | DataService only | Session locking prevents coin/pet duplication and lost saves on server hops or crashes; handles retries, budget, auto-save and `BindToClose`. Writing that ourselves is days of risky work. |
`[server-dependencies]` line: `ProfileStore = "lm-loleris/profilestore@1.0.3"` -
`TODO(verify-api)`: confirm scope/name/version with `wally search profilestore`. **Not added yet: sprint-1
integration ticket.** No framework (the bootstrap replaces Knit), no networking library (20 events), no signal lib.

### Sprint-1 integration tickets
1. Add ProfileStore to `wally.toml`, `wally install`, verify API names (section 3c).
2. `Contracts/RateLimit.luau`, `Contracts/NumberFormat.luau` (T-004, done sprint 1). `Contracts/ProductCatalog.luau` (23 keys -> ids, grant kinds, price labels) is T-069, sprint 3, after the owner approves prices.

## 7. Performance budgets (target: low-end mobile, ~2 GB RAM phone, 12 players)
| Area | Budget |
|---|---|
| Client memory (Developer Console total) | <= 700 MB on mobile; place assets <= 200 MB |
| Parts in Workspace | each world hub <= 6,000; total <= 14,000; boss models <= 150 parts each |
| Meshes / textures | <= 120 unique meshes; textures <= 512 px (1024 only for signage); pets <= 1,500 tris each |
| Pets rendered (client) | equipped pets of players within 120 studs only; <= 36 pet models alive; one Heartbeat loop with `workspace:BulkMoveTo`; no per-pet connections; no collisions/touch/query |
| Looks | <= 6 accessories per character; aura = 1 ParticleEmitter, rate <= 20 |
| Particles / sounds | <= 300 particles alive; tap sparkles pooled (20); <= 8 concurrent sounds |
| Client frame time | Effects <= 2 ms, UI <= 1 ms per frame on low-end mobile |
| Remote traffic | C->S <= 3 msgs/s avg per player (TapBatch 2/s); S->C <= 2 KB/s per player |
| Attribute writes | flushed <= 5 Hz per player; IdleService loop 1 Hz for all players |
| Server | server script time <= 6 % at 12 players; one 1 Hz loop, no per-player loops |
| DataStore | ProfileStore auto-save + on leave; leaderboard writes <= 4 per player per 60 s; reads every 120 s |
| Streaming | StreamingEnabled on; boss stages, rings and podium `Atomic`; code never assumes a part is streamed in |
qa measures these in `/sprint` builds with the Developer Console on the smallest test device.

## 8. Contract requests
Programmers add requests through their summary; team-lead routes them here. integration-programmer decides.

| # | From | Request | Status |
|---|---|---|---|
| CR-1 | team-lead (T-003, D-021) | Rev 1 product list (23) and option A: trim `ProductKey`/`GrantKind`, drop Skip Rebirth / Skip World 2 / Auto-Mog Early / coin products, remove the default coin-egg gate | **Done** (sprint 1, commit "T-003"). Notified: gameplay (`tryRebirth(player)` has no `skip`; `GrantKind` "PaidTier"/"Boost" registered by MultiplierService, "FixedPet"/"StarterPack"/"RobuxEgg" by PetService; `COIN_EGGS_POLICY_GATED = false`; `CoinReason` lost "Pack"/"StarterPack"), systems (`AutoMogEarlyOwned` attribute and `skipRebirthsUsed`/`entitlements.autoMogEarly` fields gone; schema stays v1, nothing shipped yet; `RequestPurchase` rules in section 2 #13) |
| CR-2 | team-lead (T-004) | Shared `RateLimit` and `NumberFormat` in Contracts | **Done** (sprint 1, commit "T-004"). Every C->S handler uses `RateLimit.connect` (or `check` first); every number shown to players goes through `NumberFormat` |
