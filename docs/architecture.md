# Architecture: "Aura Up!" (working title) v1
_Owned by integration-programmer. Sections: see .claude/agents/integration-programmer.md. Version 1.4, 2026-10-31
(D-017, updated for GDD rev 1 / option A in D-023, sprint-1 contract requests in D-032, sprint-2 contract requests
in D-051, ProductCatalog in D-054). Built from docs/gdd.md rev 1, approved by the owner (D-021).
Source of truth for code contracts: `src/shared/Contracts/Remotes.luau` and `src/shared/Contracts/Types.luau`.
Both must match this file. Applies lawyer rulings D-016 and D-019 (policy gate on Robux eggs only, next-tier-only
ladder, restricted receipts). Prices were approved by the owner in D-038; they live only in
`Contracts/ProductCatalog.luau` (T-069, section 4f), so a price change does not change this contract. D-038 leaves
Speed Sneakers, Neon Pup, Neon Icon Fit and the five tips out of v1: `T.ProductKey` keeps all 23 keys, and those 8
have catalog entries with `onSale = false` (D-054)._

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
- **Call-time lookups (CR-c, sprint 1).** Gameplay reaches Data, World, PetService and later-sprint modules through
  `src/server/Gameplay/Util/Deps.luau`: the module is found by name and required inside the call, never at file
  top, and every optional accessor is nil-guarded. This is the one allowed same-folder upward read:
  MultiplierService (L0) reads `PetService.getPetMultiplierSum` (L1) at refresh time. It is safe because no
  module requires up at load time (no require cycle) and Init never calls another service. The other half of the
  rule: **PetService must call `MultiplierService.refresh(player)` after every equip, unequip or delete** (4a), so
  M is never stale. No other upward lookup is allowed without a Contract request.

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
-- Added in sprint 1 (world request, accepted D-032). Safe with untrusted input (nil on bad ids).
function ZoneService.getBossWorld(bossId: string): T.WorldId?             -- from MapLayout.BOSS_IDS
function ZoneService.getBossStagePosition(bossId: string): Vector3?      -- BossStage part, else layout fallback
function ZoneService.getShopStandPosition(worldId: T.WorldId, shop: MapLayout.ShopKind): Vector3?
function ZoneService.getCharacterPosition(player: Player): Vector3?      -- live root position or nil
function ZoneService.getInteractRange(): number                          -- EconomyConfig.INTERACT_RANGE
-- isNearBoss allows INTERACT_RANGE + 6 studs of slack (lag, stage size), D-025.

-- CharacterService
function CharacterService.setLook(player: Player, lookId: string): ()        -- respects ShowOwnLook setting
function CharacterService.setSpeedMultiplier(player: Player, mult: number): ()
function CharacterService.setMovementLocked(player: Player, reason: string, locked: boolean): () -- reason-keyed
function CharacterService.getSpeedMultiplier(player: Player): number
function CharacterService.isMovementLocked(player: Player): boolean
-- setLook (T-038, D-039): lookId must be in MapLayout.LOOK_IDS (else warn + ignore). Clones only `Accessory`
-- children with a `Handle` from ServerStorage.Assets.Looks.<id> (scripts stripped, massless, no collision), owned
-- fits first (MapLayout.FIT_IDS order), cap MapLayout.MAX_LOOK_ACCESSORIES (6). Re-applied on respawn and when
-- SettingShowOwnLook, FirstWin, Vip, StarterPackOwned or MonetizationService.EntitlementsChanged changes.
-- Caller: RankService (through Deps.character) on load and rank-up.
-- ZoneService (T-038): getPod reads a 0.5 s server box check of `Pod` parts (writes CurrentPod, fires PodChanged);
-- isNearEggStand uses the boss rule (INTERACT_RANGE + 6, egg world == player world, layout fallback). The Portal
-- only sends Notify "World 2 coming Saturday!" (5 s cooldown); teleportToWorld stays unused until T-092.

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
function ShopService.refreshAttributes(player: Player): () -- rewrites ToolIndex/PodsMask from the profile;
	-- RebirthService calls it after its reset (CR-a, accepted D-032)

-- PetService
PetService.Hatched: RBXScriptSignal -- (player: Player, eggId: T.EggId, results: { T.HatchedPet })
function PetService.tryHatch(player: Player, eggId: T.EggId, count: number): (boolean, string?) -- coin eggs
function PetService.grantEgg(player: Player, eggId: T.EggId, count: number): boolean -- Robux / daily, no cost
function PetService.getPetMultiplierSum(player: Player): number -- sum of equipped bonuses (before cap)
function PetService.freeSlots(player: Player): number -- inventory space left
-- Added in sprint 2 (gameplay request CR-G2, accepted D-051). The EquipPet / DeletePets handlers call exactly
-- these after their own type checks, so qa drives the real path (QA-F8). Both re-validate every argument, end with
-- MultiplierService.refresh(player) (CR-c) and rewrite the PetService attributes (1e). Reasons: "NotLoaded",
-- "BadArgs", "NotOwned", "NoSlot".
function PetService.setEquipped(player: Player, petUid: string, equip: boolean): (boolean, string?) -- no-op = true
function PetService.deletePets(player: Player, petUids: { string }): (boolean, string?) -- 1..60 unique owned uids
-- grantEgg: coin eggs only until T-073 (S3) adds Robux rolls, pity and restrictedGrant.

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

-- IdleService: no public functions. One 1 Hz loop (D-042): pod MP via ZoneService.getPod + PodsMask, Auto-Tap via
-- TapService.addTaps(.., "Auto"), Auto-Mog via BossService.bestBeatable + tryFight(.., true) every 5 s while Idle.
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
| 21c | Contracts/ProductCatalog | integration | `src/shared/Contracts` | The only file with developer product ids and Robux prices: 23 entries (15 on sale), grant kind, price label, flags, D-019 ladder fallback, restricted egg pets (T-069, section 4f) |

MapLayout functions the UI may call (CR-4, D-032): `getBossStage(bossId): Instance?` (a Model **or** a BasePart; use
`MapLayout.positionOf(inst)` for its position, never `.Position`), `getBossStagePosition(bossId)`, `positionOf`,
`getShopStand(worldId, shop): Instance?`, `getShopKindOf(inst): ShopKind?`, `getEggStand`, `getEggIdOf`, `observe`,
`waitFor` (outside Init). There is **no** `getShopStands(kind)`: to match a ProximityPrompt to a stand, walk the
prompt's ancestors and call `getShopKindOf` (see 1f).

`Contracts/ProductCatalog.luau` (T-069, done sprint 3): ProductKey -> product id, grant kind, price label, flags.
API and rules in section 4f. Ids are placeholder 0 until the owner creates the products.

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
-- EconomyConfig surface other folders rely on (gameplay-programmer owns the values, GDD 4-7). Field names are
-- contract (CR-4, QA-F4, D-032): readers use exactly these names; `world` (not `worldId`) everywhere.
export type Tool = { name: string, mpPerTap: number, cost: number, world: number }       -- cost 0 = free
export type Pod  = { name: string, mpPerSec: number, cost: number, world: number }       -- base MP/s before M
export type Boss = { id: string, name: string, world: number, mpNeed: number, coins: number }
	-- id = builder's `BossId` (1f); mpNeed is a threshold, never spent; coins before coinRebirthMult/Coin Snack
export type Rank = { name: string, lifetimeMp: number, lookId: string }                 -- lookId = 1f model name
export type EggPet = { petId: string, weight: number }                                    -- weights sum to ODDS_TOTAL
export type Egg  = { name: string, world: number, currency: "Coins" | "Robux", price: number,
	pets: { EggPet }, restrictedGrant: string?, pityAt: number? }                         -- T-027 (D-040)
	-- price = coins per hatch on coin eggs, 0 on Robux eggs (Robux prices live in ProductCatalog)
	-- pets listed most common first; restrictedGrant (Robux eggs only) must be a pet in that egg's table
	-- pityAt (CR-G2): Robux eggs only, 10 = every 10th hatch with no Legendary+ is forced (4b); nil on coin eggs
export type Pet  = { name: string, rarity: string, bonus: number, fixed: boolean? }      -- T-027 (D-040)
	-- rarity is one of RARITIES; fixed (CR-G2) = never rolled from an egg (Robux product / Starter Pack grant)

EconomyConfig.TOOLS: { Tool }            -- array, index = tool index 1..12 (ToolIndex)
EconomyConfig.PODS: { Pod }              -- array, index = PodIndex 1..7 (PodsMask bit i)
EconomyConfig.BOSSES: { Boss }           -- ARRAY, weakest first; W1 = 1..7, W2 = 8..13
EconomyConfig.BOSS_BY_ID: { [string]: Boss } -- same rows keyed by id (use this for lookups by id)
EconomyConfig.RANKS: { Rank }            -- array, index = rank 1..12
EconomyConfig.EGGS: { [T.EggId]: Egg }   -- map by egg id: BasicEgg, ShinyEgg (coins, W1), StarEgg (Robux, W1),
                                         -- GalaxyEgg (Robux, W2); NeonEgg/RunwayEgg wait for T-090
EconomyConfig.PETS: { [T.PetId]: Pet }   -- map by pet id (ids <= 32 chars)
EconomyConfig.EGG_IDS: { T.EggId }       -- display order of the eggs in EGGS (each exactly once)
EconomyConfig.RARITIES: { T.Rarity }     -- "Common" .. "Mythic", low to high

EconomyConfig.TAP_CAP_PER_SEC: number          -- 12 (manual + auto, PvE)
EconomyConfig.TAP_BATCH_MAX: number            -- 30, largest TapBatch count (section 2 #1; TapController sends <= this)
EconomyConfig.TAP_BURST_SEC: number            -- 1, tap bucket holds this many seconds of taps
EconomyConfig.DUEL_TAP_CAP_PER_SEC: number     -- 10
EconomyConfig.M_CLAMP: number                  -- 10000 (v1; raised per world in later updates)
EconomyConfig.PET_MULT_CAP: number             -- 25
EconomyConfig.INVENTORY_CAP: number            -- 60
EconomyConfig.INVENTORY_HARD_CAP: number       -- 66 (paid receipts may exceed the cap by 6, 4b)
EconomyConfig.INTERACT_RANGE: number           -- 20 studs (boss stage, egg stand)
EconomyConfig.ODDS_TOTAL: number               -- 10000
EconomyConfig.COIN_EGGS_POLICY_GATED: boolean  -- false (option A, D-023)
EconomyConfig.BOSS_FIGHT_SEC / BOSS_COOLDOWN_SEC / BOSS_CYCLE_SEC: number -- 3 / 1 / 4
-- Eggs (CR-G2 and CR-S2b, D-051). The UI reads these names; do not add aliases.
EconomyConfig.HATCH_MULTI_COUNT: number         -- 3, the "Hatch x3" count (HatchEgg count is 1 or this)
EconomyConfig.HATCH_MULTI_REBIRTHS: number      -- 2, "Hatch x3 at Rebirth 2" (CR-S2b: this is the name)
EconomyConfig.HATCH_LOCK_SEC: number            -- 1, server Hatching activity; the reveal animation is client-only
EconomyConfig.AUTO_DELETE_RARITY: T.Rarity      -- "Common", what the auto-delete setting removes
EconomyConfig.PITY_LEGENDARY_WEIGHT: number     -- 9000 } forced pity roll weights, sum = ODDS_TOTAL (4b)
EconomyConfig.PITY_MYTHIC_WEIGHT: number        -- 1000 }
-- Automation (read by IdleService and the Settings/HUD UI): AUTO_TAP_FREE_RANK 3, AUTO_TAP_FREE_RATE 3,
-- AUTO_CLICKER_RATE 6, AUTO_MOG_REBIRTHS 1, AUTO_MOG_INTERVAL_SEC 5. Pet slots: PET_SLOTS_BASE 3,
-- PET_SLOT_REBIRTHS { 3, 8 }, PET_SLOTS_VIP 1.
-- Also: REBIRTH_*, WORLD2_REBIRTHS, AUTO_TAP_*, AUTO_CLICKER_RATE, AUTO_MOG_*, PET_SLOT*, VIP/HYPE/COIN_SNACK
-- multipliers, BOOST_CAP_SEC, HYPE_SNACK_SEC, SPEED_SNEAKERS_SEC, SPEED_WALK_MULT, DUEL_* timings and caps.
function EconomyConfig.rebirthCost(n: number): number            -- 15000 x 3^(n-1)
function EconomyConfig.rebirthMult(rebirths: number): number     -- 1 + 0.5 x rebirths
function EconomyConfig.coinRebirthMult(rebirths: number): number -- 1 + 0.1 x rebirths
function EconomyConfig.paidTierMult(tier: number): number        -- 1, 2, 4, 8, 16, 32
function EconomyConfig.petSlots(rebirths: number, vip: boolean): number -- 3, +1 R3, +1 R8, +1 VIP
function EconomyConfig.duelScore(taps: number, ownRank: number, oppRank: number): number
function EconomyConfig.rankForLifetimeMp(lifetimeMp: number): number   -- 1..12
function EconomyConfig.bossCoinsPerSec(boss: Boss, rebirths: number): number -- coins x coinRebirthMult / cycle
function EconomyConfig.validate(): () -- asserts table shapes and egg weight sums; BossService.Init + qa tests
```
**Two boss-id lists must agree:** `EconomyConfig.BOSSES` (ids + `world`) is the source of truth for gameplay and
UI; `MapLayout.BOSS_IDS` (per world, same order) is World's copy for the map fallback. qa adds a test that they
are equal (checked equal at the sprint-1 merge).

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
| PetInventory (CR-S2a): comma list of `uid:petId:e`, e = `1` equipped / `0` not, sorted by numeric uid, `""` when empty, <= 66 entries (~1.5 KB max). Written on load and after every hatch, grant, equip, unequip and delete (never on a timer). Read by UI/PetsController and EggController's "you own" ticks via `UI/Util/PetInventory` | string | PetService |
| FirstWin, BestCoinsPerSec | boolean, number | BossService |
| MpPerTap | number (ToolPower x M) | TapService |
| RebirthCost | number | RebirthService |
| IdleMpPerSec, AutoTapRate, AutoTapUnlocked, AutoMogUnlocked | number, number, boolean, boolean | IdleService (1 Hz). AutoTapUnlocked = Rank >= `AUTO_TAP_FREE_RANK` or Auto Clicker owned; AutoMogUnlocked = Rebirths >= `AUTO_MOG_REBIRTHS` (CR-3, CR-S2c). DataService's `SetSetting` and UI/SettingsController read these two attributes and never recompute the rule |
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
**Look and fit names (world request CR-W2, D-051): the lists are `MapLayout.LOOK_IDS` (12 rank looks, must equal
`EconomyConfig.RANKS[i].lookId` in order; checked equal at the sprint-2 merge) and `MapLayout.FIT_IDS` (5 fits, in
wear priority: `GoldenGlowFit`, `NeonIconFit`, `VipSparkleAura`, `RookieShades`, `StarterFit`).** Each is a model
in `ServerStorage.Assets.Looks` holding `Accessory` children only (CharacterService ignores anything else). The
names below are a copy for the builder; MapLayout wins if they ever differ.

**Builder handoff ids (CR-b, D-032).** The full tag/attribute contract is the header of
`src/shared/World/MapLayout.luau`.
- `BossId` values (13): World 1 `SleepySid`, `BedheadBenny`, `SweatbandSal`, `CaptainCardio`, `DukeOfDrip`,
  `GlowQueen`, `AuraTitan`; World 2 `LaserLarry`, `DjDazzle`, `ChromeChamp`, `RunwayRex`, `DivaSupreme`, `KingShine`.
- Look ids (model names in `ServerStorage.Assets.Looks`, 12): `FreshSpawn`, `CombRookie`, `GlowStarter`,
  `DripApprentice`, `StyleScout`, `MainCharacter`, `Trendsetter`, `AuraFarmer`, `Icon`, `SpotlightLegend`,
  `StarMogger`, `SupremeMogger`.
- **ProximityPrompts on stands (CR-4 decision): builder creates them.** Each `ShopStand` and `EggStand` holds one
  `ProximityPrompt` as a descendant (ActionText "Open Shop" / "Open Egg", HoldDuration 0, MaxActivationDistance 10,
  RequiresLineOfSight off). No code creates or edits prompts. The client matches a triggered prompt by walking its
  ancestors and calling `MapLayout.getShopKindOf` / `getEggIdOf`. Prompts only open UI; they never buy (0, GDD 8b).

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
| 13 | RequestPurchase | C->S | `productKey: string` | len <= 24; `ProductCatalog.canSell(key)` (key known, on sale, product id not 0; section 4f); `FirstWin` (GDD 8a, all products); Robux eggs need `PaidRandomAllowed` and `freeSlots >= count`; fixed pets and Starter Pack need `freeSlots >= 1`; ladder tier `== PaidTier + 1` only (D-016 #8); permanent items (AutoClicker, Vip, fits) not owned; Starter Pack once; Hype Snack / Speed Sneakers refused when the 2 h cap would be exceeded (GDD 8h); tips always allowed. This is a **prompt** gate only (UX, D-016 #9); then server calls `MarketplaceService:PromptProductPurchase(player, id)` | 0.5 / 2 | Data/MonetizationService (UI/ShopController, EggController) |
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
-- Data-internal (CR-3, accepted D-032): only MonetizationService may call it (ProcessReceipt step 5, 3c).
function DataService.saveAndConfirm(player: Player, predicate: (saved: { [any]: any }) -> boolean,
	timeoutSec: number?): boolean -- **yields**; saves now, true once a save passing `predicate` is written
```
`ProfileLoaded`/`ProfileReleasing` exist only after `DataService:Init()`; connect to them in `Start()`.
Sprint 1 runs on the `LockedStore` UpdateAsync fallback until ProfileStore is installed with wally (D-028).
Saving: ProfileStore auto-save, on leave (`EndSession`), and on shutdown (ProfileStore's `BindToClose`).

### 3c. ProcessReceipt and receipt-id dedupe (MonetizationService, the only assigner of `ProcessReceipt`)
1. Find the player by `receiptInfo.PlayerId`; if absent or profile not loaded -> `NotYetProcessed` (Roblox retries).
2. If `PurchaseId` is in `profile.receipts` -> `PurchaseGranted` (already granted; idempotent).
3. Look up the entry with `ProductCatalog.byProductId(receiptInfo.ProductId)`; nil (unknown id, or a key not on
   sale) -> log + `NotYetProcessed`.
4. In **one** `DataService.update`: call the registered grant fn for the key's `GrantKind` with that update's
   `data` table, then append the PurchaseId (trim to 100). If the grant returns false, nothing is recorded and the
   answer is `NotYetProcessed`. After the update, fire `EntitlementsChanged` so services refresh attributes.
5. Wait for the profile save that contains that PurchaseId, then return `PurchaseGranted`. If the session ends
   first -> `NotYetProcessed`.
Every valid paid receipt is delivered (D-016 #9): the FirstWin rule gates prompts, never receipts. A Robux-egg
receipt for a player whose `PaidRandomAllowed` is false grants the egg's **disclosed non-random outcome**
(`ProductCatalog.restrictedGrant(key)`: the fixed pet, x3 for a 3-pack, also stated in the product description; the
pet id equals `EconomyConfig.EGGS[eggId].restrictedGrant`), never a random roll and never nothing (D-016 #4). No product bundles an egg (D-016 #5).
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
- **`src/server/Gameplay/Util/PetRoll.luau`** (gameplay, CR-G2, D-051) is the pure roller. PetService passes its
  Random; qa passes a seeded one (QA-F7). Server-only (it lives under ServerScriptService):
  ```luau
  function PetRoll.total(entries: { EconomyConfig.EggPet }): number                  -- sum of weights
  function PetRoll.pickWithRoll(entries: { EconomyConfig.EggPet }, r: number): string -- r in [1, total], walks in order
  function PetRoll.pick(pets: { EconomyConfig.EggPet }, rng: Random): string         -- PetId
  ```
- Order of a coin hatch (D-041): roll first, check space with auto-delete applied, then charge + insert + (later)
  pity in one `DataService.update` that re-checks coins and space. A refused hatch charges nothing and sends nothing.
- **Pity (Robux eggs only):** `pity[eggId]` counts hatches since the last Legendary-or-better. On the 10th
  (`pity == Egg.pityAt - 1` before rolling) with no hit, the roll is forced to the Legendary/Mythic subset weighted
  `PITY_LEGENDARY_WEIGHT` / `PITY_MYTHIC_WEIGHT` (90/10). Any
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
| MpX2, MpX4, MpX8, MpX16, MpX32 | PaidTier | MultiplierService | `ProductCatalog.ladderGrant(key, paidTier)`: next tier -> `entitlements.paidTier` = that tier; any other receipt (owned, lower or skip-ahead tier) -> Hype Snack time, 10 min per 2 R$, cap bypassed, logged, **never the next tier** (D-019 #3, part of T-053 per D-038) |
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

### 4f. Product catalog (`src/shared/Contracts/ProductCatalog.luau`, T-069, D-054)
The only place with developer product ids and Robux prices (D-038). Pure data and pure functions, no Roblox API
calls; server and client may both require it (the client uses it for labels and descriptions only).

**Product ids are placeholder `0`.** `TODO(owner)`: the owner creates each on-sale product in Creator Hub (checklist
below) and pastes its numeric id into the entry's `productId`. An id of 0 can never be sold or granted:
`canSell` returns `false, "NoProductId"` and `byProductId(0)` returns nil. Product ids are not secrets.

| Key | Product name | Price | GrantKind | Repeatable | Next tier only | Extra fields |
|---|---|---|---|---|---|---|
| MpX2 | x2 Mog Points | 4 R$ | PaidTier | no (permanent) | yes | tier 1, multiplier 2 |
| MpX4 | x4 Mog Points | 8 R$ | PaidTier | no (permanent) | yes | tier 2, multiplier 4 |
| MpX8 | x8 Mog Points | 19 R$ | PaidTier | no (permanent) | yes | tier 3, multiplier 8 |
| MpX16 | x16 Mog Points | 39 R$ | PaidTier | no (permanent) | yes | tier 4, multiplier 16 |
| MpX32 | x32 Mog Points | 79 R$ | PaidTier | no (permanent) | yes | tier 5, multiplier 32 |
| HypeSnack | Hype Snack | 2 R$ | Boost | yes | no | hypeSec 600 |
| AutoClicker | Auto Clicker | 39 R$ | Entitlement | no (permanent) | no | |
| RingLightRetriever | Ring Light Retriever | 29 R$ | FixedPet | yes (one copy each) | no | petId RingLightRetriever |
| GoldenGlowFit | Golden Glow Fit | 249 R$ | Entitlement | no (permanent) | no | |
| Vip | VIP | 99 R$ | Entitlement | no (permanent) | no | |
| StarterPack | Starter Pack | 9 R$ | StarterPack | no (once) | no | hypeSec 1800, petId SparklePup |
| StarEgg1 | Star Egg | 25 R$ | RobuxEgg | yes | no | eggId StarEgg, count 1, restrictedPetId StarlightCorgi |
| StarEgg3 | Star Egg x3 | 69 R$ | RobuxEgg | yes | no | eggId StarEgg, count 3, restrictedPetId StarlightCorgi |
| GalaxyEgg1 | Galaxy Egg | 49 R$ | RobuxEgg | yes | no | eggId GalaxyEgg, count 1, restrictedPetId NebulaFox |
| GalaxyEgg3 | Galaxy Egg x3 | 129 R$ | RobuxEgg | yes | no | eggId GalaxyEgg, count 3, restrictedPetId NebulaFox |
| SpeedSneakers, NeonPup, NeonIconFit, Tip5, Tip25, Tip100, Tip500, Tip1000 | - | **not on sale** (D-038) | Boost / FixedPet / Entitlement / Donation | - | no | `onSale = false`, price 0, never created, never prompted, never granted |

**API (Luau types):**
```luau
export type Entry = {
	key: ProductKey, productId: number, grantKind: GrantKind, onSale: boolean,
	priceRobux: number, priceLabel: string, repeatable: boolean, nextTierOnly: boolean,
	tier: number?, multiplier: number?, hypeSec: number?, petId: PetId?,
	eggId: EggId?, count: number?, restrictedPetId: PetId?, displayName: string, description: string,
}
export type LadderGrant = { tier: number?, hypeSec: number }
export type RestrictedGrant = { petId: PetId, count: number }

ProductCatalog.Entries: { [ProductKey]: Entry }          -- all 23, frozen
ProductCatalog.OnSaleKeys: { ProductKey }                -- the 15 on sale, in Types.ProductKeys order (shop lists)
ProductCatalog.HYPE_FALLBACK_SEC_PER_ROBUX = 300         -- 10 min per 2 R$ (D-019 #3)
ProductCatalog.LADDER_TIERS = 5
function ProductCatalog.get(key: string): Entry?                       -- nil for any non-key string (raw client input)
function ProductCatalog.byProductId(productId: number): Entry?         -- ProcessReceipt lookup; nil for 0 / unknown
function ProductCatalog.ladderKey(tier: number): ProductKey?           -- 1..5 -> MpX2..MpX32
function ProductCatalog.canSell(key: string): (boolean, string?)       -- false + "UnknownKey" | "NotOnSale" | "NoProductId"
function ProductCatalog.ladderGrant(key: ProductKey, ownedTier: number): LadderGrant
function ProductCatalog.restrictedGrant(key: ProductKey): RestrictedGrant  -- RobuxEgg keys only
function ProductCatalog.missingIds(): { ProductKey }                   -- on-sale keys still on id 0; log once at Start
```

**Who uses what:**
- MonetizationService (T-053): `RequestPurchase` calls `canSell(key)` first, then the section 2 #13 gates; prompts
  `entry.productId`. Never prompts `nextTierOnly` keys unless `entry.tier == PaidTier + 1`; never re-prompts a key
  with `repeatable = false` that the player owns. `ProcessReceipt` uses `byProductId` and dispatches on
  `entry.grantKind`. `Start()` logs `missingIds()` as one warning (expected in Studio until the owner adds ids).
- MultiplierService PaidTier grant: `ladderGrant(entry.key, data.entitlements.paidTier)`. If `tier` is set, write it;
  otherwise add `hypeSec` to `boosts.hypeSec` (2 h cap bypassed for this grant) and log the event. **D-019 rule:**
  a receipt for an owned, lower or skip-ahead tier always gives Hype Snack time and **never** the next tier, so a
  forced 4 R$ receipt cannot climb the ladder. Boost grant: add `entry.hypeSec`.
- PetService: FixedPet / StarterPack grant `entry.petId` (Starter Pack also `entry.hypeSec`); RobuxEgg rolls
  `entry.count` times from `entry.eggId`, or, when `PaidRandomAllowed` is false, grants
  `restrictedGrant(key)` (Star Egg -> Starlight Corgi, Galaxy Egg -> Nebula Fox, a 3-pack gives 3 copies; no roll,
  pity unchanged).
- UI (ShopController): `OnSaleKeys`, `entry.displayName`, `entry.priceLabel`, `entry.description`. Prices shown come
  from here only. Never sends anything but the key.
- qa: the catalog asserts at load that it has exactly one entry per `Types.ProductKeys` key (23), that `onSale`
  matches a non-zero price, that all 5 ladder tiers exist and that filled-in ids are unique. qa adds: every
  `restrictedPetId` equals `EconomyConfig.EGGS[eggId].restrictedGrant`, and the 8g firewall walks all 23 entries.

### Owner: create developer products
`TODO(owner)`: create these 15 developer products in Creator Hub for this experience, one per row, with the name,
price and description below. Then send the 15 product ids to team-lead (or paste each into the matching
`productId` in `src/shared/Contracts/ProductCatalog.luau`); integration-programmer commits them. Product ids are not
secrets. Do **not** create Speed Sneakers, Neon Pup, Neon Icon Fit or any tip: they are outside the approved scope
(D-038). The exact Creator Hub menu steps are not described here because they were not verified.

| # | Key | Name | Price (R$) | Description |
|---|---|---|---|---|
| 1 | MpX2 | x2 Mog Points | 4 | x2 Mog Points from tapping, pods and auto taps. Permanent. Does not stack: the highest tier you own applies. |
| 2 | MpX4 | x4 Mog Points | 8 | x4 Mog Points from tapping, pods and auto taps. Permanent. Does not stack: the highest tier you own applies. |
| 3 | MpX8 | x8 Mog Points | 19 | x8 Mog Points from tapping, pods and auto taps. Permanent. Does not stack: the highest tier you own applies. |
| 4 | MpX16 | x16 Mog Points | 39 | x16 Mog Points from tapping, pods and auto taps. Permanent. Does not stack: the highest tier you own applies. |
| 5 | MpX32 | x32 Mog Points | 79 | x32 Mog Points from tapping, pods and auto taps. Permanent. Does not stack: the highest tier you own applies. |
| 6 | HypeSnack | Hype Snack | 2 | x2 Mog Points for 10 minutes. Boost time runs only while you are in the game. Stacks up to 2 hours. |
| 7 | AutoClicker | Auto Clicker | 39 | Permanent. 6 automatic taps per second for Mog Points. |
| 8 | RingLightRetriever | Ring Light Retriever | 29 | One Ring Light Retriever pet (+1.00 Mog Points bonus). Not random. |
| 9 | GoldenGlowFit | Golden Glow Fit | 249 | Permanent. Exclusive outfit and aura. Cosmetic only, no stats. |
| 10 | Vip | VIP | 99 | Permanent. x1.25 Mog Points, +1 pet slot, gold name tag, VIP Sparkle Aura and +10 min Hype Snack on each daily reward claim. |
| 11 | StarterPack | Starter Pack | 9 | One time only. 30 min Hype Snack, Sparkle Pup pet (+0.30 Mog Points bonus) and Rookie Shades cosmetic. |
| 12 | StarEgg1 | Star Egg | 25 | 1 Star Egg hatch. Odds are shown in game before you buy. Every 10th hatch with no Legendary or better is a guaranteed Legendary (90%) or Mythic (10%). If random items are not available on your account, you get Starlight Corgi (no random roll). |
| 13 | StarEgg3 | Star Egg x3 | 69 | 3 Star Egg hatches. Odds are shown in game before you buy. Every 10th hatch with no Legendary or better is a guaranteed Legendary (90%) or Mythic (10%). If random items are not available on your account, you get 3 x Starlight Corgi (no random roll). |
| 14 | GalaxyEgg1 | Galaxy Egg | 49 | 1 Galaxy Egg hatch. Odds are shown in game before you buy. Every 10th hatch with no Legendary or better is a guaranteed Legendary (90%) or Mythic (10%). If random items are not available on your account, you get Nebula Fox (no random roll). |
| 15 | GalaxyEgg3 | Galaxy Egg x3 | 129 | 3 Galaxy Egg hatches. Odds are shown in game before you buy. Every 10th hatch with no Legendary or better is a guaranteed Legendary (90%) or Mythic (10%). If random items are not available on your account, you get 3 x Nebula Fox (no random roll). |

Each description is the same text as the entry's `description` field in ProductCatalog. Before go-live, lawyer re-reads these texts against docs/legal.md (wording rules GDD 8e, 8h, 8i).

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

**Who calls what (systems request CR-S2d, D-051; verified in the sprint-2 merge).** Gameplay calls TelemetryService
only through `Gameplay/Util/Deps.funnel(player, step)` and `Deps.economy(player, flow, amount, reason)`, which look
the service up at call time and `task.spawn` it (never errors, never yields the caller). Coins are logged by the
service that moves them, never inside `DataService.addCoins/trySpendCoins` (D-047).
| Caller | Funnel | Economy |
|---|---|---|
| TapService | FirstTap | - |
| BossService | FirstWin | Source BossWin (coins actually added, QA-8) |
| ShopService | FirstUpgrade, FirstPod | Sink Tool, Sink Pod |
| RankService | FirstRankUp | - |
| PetService | FirstEgg (every HatchResult) | Sink Egg (coin hatch, inside its raw update) |
| RebirthService | FirstRebirth | Sink Rebirth (the cost; coins above it are reset, not logged) |
| TelemetryService itself | Spawn (ProfileLoaded), TutorialDone + FirstRebirth (attributes) | - |
| Sprint 3: RewardService, DuelService, QuestService | - | Source Daily / Code / DuelReward |
Repeats are cheap (milestones lookup). `custom` (Purchase, Duel*) is MonetizationService / DuelService, sprint 3.

## 6. Startup order and packages
### Server (`src/server/Main.server.luau`, T-026)
1. `Remotes.setup()` creates `ReplicatedStorage.Remotes` with every remote.
2. Require services in this explicit order (missing ones are skipped; an unlisted direct-child module is loaded
   last in its folder with a warning):
   Data: DataService, ComplianceService, TelemetryService, MonetizationService, LeaderboardService.
   World: ZoneService, CharacterService.
   Gameplay: ActivityService, MultiplierService (L0); RankService, ShopService, PetService, BossService (L1);
   TapService, RebirthService (L2); IdleService, DuelService, QuestService, RewardService (L3).
3. `Init()` on all, same order (local state, BindableEvents, no yields, no cross-service calls). An Init error
   stops the boot with the service name and a traceback.
4. `Start()` on all, same order, each via `task.spawn` (errors keep their own trace): grants registered, remotes
   and signals connected, loops started. Services may be written `X.Init()` or `X:Init()`; the bootstrap passes
   the module as `self`. DataService's Start yields (backend probe) before loading players, so every other Start
   has connected `ProfileLoaded` before the first profile loads; Starts still handle players already present.
Player join: DataService loads (yields) -> `ProfileLoaded` -> MonetizationService applies entitlements,
ComplianceService checks policy, ZoneService sets world, Gameplay services compute their attributes,
MultiplierService refreshes. Every handler checks `DataLoaded` first, so early remotes are dropped.
Player leave: Gameplay drops per-player state (DuelService forfeits, rings released), DataService ends the session.

### Client (`src/client/Main.client.luau`, T-026)
Wait for `game.Loaded`, then require in order: UI: NotificationController, HudController, TapController,
ShopController, EggController, PetsController, SettingsController, RewardsController, DuelController; Effects:
EffectsController, PetFollowController, CinematicController, RagdollController. `Init()` all, then `Start()` all. Controllers wait for `DataLoaded == true` and handle
map parts streaming in/out (StreamingEnabled is on).
Helpers that are not controllers live in subfolders and are skipped by the bootstrap: `UI/Util` (GameData, Ui,
UiEvents, PetInventory), `UI/Panels` (started by their host controller: `RebirthPanel` by HudController, D-048),
`Effects/Util` (EffectPool).
**HatchResult has two listeners by design** (no UI <-> Effects require): `Effects/CinematicController` plays the
~2 s reveal overlay (DisplayOrder 45, D-045) and `UI/EggController` shows its result panel after its own ~2 s
wait (D-049), so the panel appears as the reveal ends. Both only draw the payload; neither rolls or changes it.
`PlayEffect RankUp` is handled only by CinematicController (D-044); `Rebirth`, `BossWin` etc. by EffectsController.

### Sprint-2 integration (T-048, D-051)
Both bootstraps already listed every sprint-2 module in dependency order (sprint-1 T-026), so no order change was
needed: server Data `TelemetryService`, Gameplay `PetService` (L1), `RebirthService` (L2), `IdleService` (L3);
client UI `EggController`, `PetsController`, `SettingsController`, Effects `PetFollowController`,
`CinematicController`. `QuestService`, `DuelService`, `RewardService`, `MonetizationService`, `LeaderboardService`,
`RewardsController`, `DuelController` and `RagdollController` are still skipped (sprint 3).

### Wally packages
| Package | Realm | Use | Why |
|---|---|---|---|
| ProfileStore (loleris) | server | DataService only | Session locking prevents coin/pet duplication and lost saves on server hops or crashes; handles retries, budget, auto-save and `BindToClose`. Writing that ourselves is days of risky work. |
`[server-dependencies]` line: `ProfileStore = "lm-loleris/profilestore@1.0.3"` -
`TODO(verify-api)`: confirm scope/name/version with `wally search profilestore`. **Not added yet: sprint-1
integration ticket.** No framework (the bootstrap replaces Knit), no networking library (20 events), no signal lib.

### Sprint-1 integration tickets
1. Add ProfileStore to `wally.toml`, `wally install`, verify API names (section 3c).
2. `Contracts/RateLimit.luau`, `Contracts/NumberFormat.luau` (T-004, done sprint 1). `Contracts/ProductCatalog.luau` (23 keys -> ids, grant kinds, price labels) is T-069, done sprint 3 with placeholder ids (section 4f).

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
| Attribute writes | flushed <= 5 Hz per player; IdleService loop 1 Hz for all players; `PetInventory` (<= ~1.5 KB) only on pet events, never on a timer |
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
| CR-a | gameplay (T-010, T-006) | Public `ShopService.refreshAttributes`; EconomyConfig extra fields (TAP_BATCH_MAX, TAP_BURST_SEC, BOSS_BY_ID, ODDS_TOTAL, INVENTORY_HARD_CAP, boss timings, rankForLifetimeMp, bossCoinsPerSec, ...) | **Accepted** (D-032). Listed in 1b and 1c |
| CR-b | gameplay (T-009, T-011) | Boss ids and rank look ids into the builder handoff | **Accepted** (D-032). In 1f "Builder handoff ids"; ids match `MapLayout.BOSS_IDS` |
| CR-c | gameplay (T-007) | MultiplierService reads PetService at call time | **Accepted with a condition** (D-032): only through `Gameplay/Util/Deps` at call time (1a); PetService must call `MultiplierService.refresh` after equip/unequip/delete (S2, T-027/T-028) |
| CR-W1 | world (T-016) | ZoneService adds getBossWorld, getBossStagePosition, getShopStandPosition, getCharacterPosition, getInteractRange | **Accepted** (D-032). Listed in 1b |
| CR-3 | systems (T-012) | `DataService.saveAndConfirm`; an owner for an `AutoTapUnlocked` attribute | **Accepted** (D-032). saveAndConfirm is Data-internal (3b). `AutoTapUnlocked` added to `Types.PlayerAttr`, writer **IdleService** (S2); DataService switches its SetSetting check to the attribute when IdleService lands |
| CR-4 | systems (T-014, T-015) | UI field names for BOSSES/TOOLS/RANKS; `MapLayout.getBossStage`, `getShopStands(kind)`; who creates the Tool Stand ProximityPrompt | **Decided** (D-032). Canonical names are EconomyConfig's as merged (1c: `world`, not `worldId`; BOSSES is an array + BOSS_BY_ID). `getBossStage` exists but may return a Model; `getShopStands` will not be added: use `getShopKindOf` on the prompt's ancestors. Builder creates the stand prompts (1f). Follow-up fixes in docs/qa/build-1.md (systems) |
| QA-F4 | qa (T-024) | Name the EconomyConfig entry fields and BOSSES shape; add TAP_BATCH_MAX to 1c | **Done** (D-032). 1c lists every entry type; pods use `mpPerSec`, bosses `mpNeed`/`coins`/`world`, tools `mpPerTap`/`cost`/`world`, ranks `lifetimeMp`/`lookId` |
| CR-G2 | gameplay (T-027, T-028, QA-F7, QA-F8) | `PetService.setEquipped` / `deletePets` in 1b; `Util/PetRoll` in 4b; `Egg.pityAt`, `Pet.fixed` and constants HATCH_*, AUTO_DELETE_RARITY, PITY_*_WEIGHT, RARITIES, EGG_IDS in 1c | **Accepted** (D-051), as merged. Listed in 1b, 1c and 4b. 4b pity now reads `pityAt` and the PITY weights |
| CR-W2 | world (T-038) | Point 1f at `MapLayout.LOOK_IDS` / `FIT_IDS` for look and fit names | **Accepted** (D-051). 1f names MapLayout as the source; LOOK_IDS checked equal to `RANKS[i].lookId` at merge |
| CR-S2a | systems (T-035, T-036) BLOCKER for the Pets panel | `PetInventory` attribute with pet uids, PetService the single writer | **Accepted** (D-051) with systems' format: `uid:petId:e` comma list, sorted by numeric uid, `""` when empty (1e). `Types.PlayerAttr.PetInventory` added. **Open: PetService must write it** (gameplay fix, sprint-2 FIX); `UI/Util/PetInventory` switches to `Attr.PetInventory` |
| CR-S2b | systems (T-035) | Name the "Hatch x3 at Rebirth 2" constant | **Decided** (D-051): `EconomyConfig.HATCH_MULTI_REBIRTHS` (count `HATCH_MULTI_COUNT`). No alias is added; `UI/Util/GameData` must read this name (systems fix) |
| CR-S2c | systems (T-034) | Attribute names `AutoTapUnlocked` / `AutoMogUnlocked`, written by IdleService | **Accepted** (D-051). Both in `Types.PlayerAttr`, writer IdleService (1e); SetSetting already reads them (QA-3) |
| CR-T069 | integration (T-069, D-038) | Trim the 8 out-of-scope keys from `T.ProductKey`, or keep them | **Decided** (D-054): keep all 23 keys; the 8 have `onSale = false` in ProductCatalog. No type change, so no rename across folders. Notified: gameplay (T-053 uses `canSell`, `byProductId`, `ladderGrant`, `restrictedGrant`), systems (shop lists `OnSaleKeys`), qa (checks in 4f) |
| CR-S2d | systems (T-033) | Telemetry hooks: `Deps.funnel` / `Deps.economy` calls from Gameplay | **Accepted and verified** (D-051): every step and coin flow in section 5 "Who calls what" is called in the merged code; nothing missing for sprint 2 |
