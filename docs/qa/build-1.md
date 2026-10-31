# Build 1 (sprint 1 merge)
_Content authored by **integration-programmer** (T-026 merge summary). The guard-write hook blocks that role from
`docs/qa/`, so qa copied it here unchanged in substance on 2026-10-31. qa's own results are in
`docs/qa/report-sprint1.md`._

**Build:** `main` at `dde2064` (code-only sprint, D-022: no Studio run, no Luau type check).

## 1. Merge
All 5 sprint-1 branches merged `--no-ff` into `main`:

| Branch | Merge commit |
|---|---|
| prog/world/sprint-1 | d726dfd |
| prog/gameplay/sprint-1 | 85e68f5 |
| prog/physics/sprint-1 | 67f01fe |
| prog/systems/sprint-1 | 75675be |
| prog/qa/sprint-1 | 8d11c76 |

Then T-026: `8e5e610` (bootstraps) and `dde2064` (contract requests). Only `docs/decisions.md` conflicted; the
branch entries were renumbered: world D-025, gameplay D-026, physics D-027, systems D-028 to D-030, qa D-031,
integration D-032.

## 2. Contracts (docs/architecture.md v1.2, D-032)
- Accepted: CR-a, CR-b, the world ZoneService additions, CR-3 (`saveAndConfirm` stays Data-internal; new
  `AutoTapUnlocked` attribute in `Types.luau`, written by IdleService), QA-F4.
- CR-c: only through `Gameplay/Util/Deps` call-time lookups. PetService must call `MultiplierService.refresh`
  after equip, unequip and delete.
- CR-4: EconomyConfig's merged names are the contract (`world`, not `worldId`; `BOSSES` array plus `BOSS_BY_ID`).
  There is no `MapLayout.getShopStands`; builder places the stand ProximityPrompts.
- `Remotes.luau` unchanged (20 RemoteEvents).

## 3. T-026 bootstraps
Server and client bootstraps load modules in an explicit dependency order (server: Data, World, Gameplay L0 to L3;
client: UI then Effects), call every Init, then every Start. The client waits for `game.Loaded`.

## 4. Checks run by integration
- StyLua and Selene: 0 errors, 0 warnings. Both `rojo build`s pass.
- `check_handlers.py`: 6 FAIL / 11 PENDING. All 6 FAILs are checker false positives (hand-verified).
- `timing_sim.py`: 2 FAIL, which are the GDD findings QA-F1 and QA-F2.
- No Studio run (D-022), no Luau type check.

## 5. Bugs found by integration
| Role | Severity | Bug |
|---|---|---|
| systems | S2 | `GameData.isShopPrompt` calls the nonexistent `MapLayout.getShopStands`, so the Tool Stand never opens the shop. Fix: walk the prompt's ancestors with `getShopKindOf`. |
| systems | S2 | `GameData.bossStage` rejects Model stages, so the MOG button and the guide arrow stay hidden. Fix: `MapLayout.positionOf` in the 2 HudController callers. |
| systems | S3 | SetSetting's AutoTap check should read `AutoTapUnlocked` once IdleService lands. |
| gameplay | S3 | `BossService.tryFight` treats any truthy `auto` as Auto-Mog (check `auto == true`). |
| gameplay | S2 (sprint 2) | PetService must call `MultiplierService.refresh` (CR-c). |
| qa | S3 | Checker false positives: the one-line `Init() end` regex runs into Start; `Guard.*` validators are not recognised. Add an EconomyConfig to MapLayout boss-id match test. |

world and physics: nothing. scenarist: QA-F1, QA-F2 and QA-F3 open at merge time.

qa filed all of these in `docs/qa/bugs.md` (QA-1 to QA-7).
