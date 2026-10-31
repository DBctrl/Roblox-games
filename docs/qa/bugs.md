# QA bugs and findings
_Owned by qa. project-manager copies open items into docs/backlog.md. Severity: S1 crash/data loss/exploit,
S2 broken feature, S3 minor/polish. Bugs (QA-n) are code bugs. Findings (QA-Fn) are design or doc issues for the
named role. Line numbers are for `main` at `dde2064` (build 1)._

## Open

### QA-1 [systems] Tool Stand prompt never opens the shop   S2
- **Found by:** integration-programmer (build 1 merge), confirmed by qa review.
- **File:** `src/client/UI/Util/GameData.luau:189-205` (`isShopPrompt`), caller `src/client/UI/ShopController.luau:211`.
- **Steps:** build the map with a `ShopStand` (`Shop = "Tools"`) holding a ProximityPrompt; walk up and trigger it.
- **Expected:** the Tool Stand panel opens (CR-4, architecture 1f).
- **Actual:** `isShopPrompt` calls `MapLayout.getShopStands`, which does not exist (CR-4 dropped it), so it always
  returns false and the panel never opens from the stand. The HUD "Tools" button (HudController:219-221) still opens it, so this is a broken stand, not a blocked shop.
- **Fix hint:** walk `prompt` up through its ancestors and return true when
  `MapLayout.getShopKindOf(ancestor) == kind` (stop at `workspace`).

### QA-2 [systems] MOG button and guide arrow hidden when a boss stage is a Model   S2
- **Found by:** integration-programmer, confirmed by qa review.
- **File:** `src/client/UI/Util/GameData.luau:175-186` (`bossStage` keeps only `BasePart`), callers
  `src/client/UI/HudController.luau:336-338` (`stage.Position`) and `:442`.
- **Steps:** builder tags a boss **Model** `BossStage` (the documented layout, ModelStreamingMode Atomic); stand
  next to Sleepy Sid with 100+ MP.
- **Expected:** the MOG button shows and pulses; before the first win the arrow points at the stage.
- **Actual:** `MapLayout.getBossStage` returns the Model, `bossStage` returns nil, so `meterTarget` finds no boss:
  no MOG button, no arrow. The first-minute flow (GDD 9) is blocked on touch devices.
- **Fix hint:** have `GameData.bossStage` return a position via `MapLayout.positionOf(stage)` (Vector3?) and use it
  in both HudController callers (the arrow needs an Attachment/part: use the Model's PrimaryPart or the pivot).

### QA-8 [gameplay] Boss win reports the coin balance as the coins won   S2
- **Found by:** qa code review (build 1).
- **File:** `src/server/Gameplay/BossService.luau:125` (`local added = dataApi.addCoins(...)`), used at `:136-138`.
- **Steps:** have 5,000 coins, beat Sleepy Sid (10 coins).
- **Expected:** `BossWon` fires with coins = 10, `PlayEffect BossWin` amount = 10, telemetry Source = 10
  (architecture 1b: `BossWon(player, bossId, coins, auto)`).
- **Actual:** `DataService.addCoins` returns the **new balance** (`DataService.luau:337-349`), so all three get
  5,010. The coin burst size is wrong today; QuestService and TelemetryService (sprint 2) would count wrong
  amounts (an economy Source log inflated by the whole balance on every win).
- **Fix hint:** `local added = if dataApi.addCoins(player, coins, "BossWin") > 0 then coins else 0`. Optionally,
  integration-programmer adds "returns the new balance" to architecture 3b so the next caller doesn't trip.

### QA-3 [systems] SetSetting AutoTap check uses its own copy of the unlock rule   S3
- **Found by:** integration-programmer (CR-3).
- **File:** `src/server/Data/DataService.luau:237-243` (`autoTapAvailable`), used at `:262`.
- **Expected:** reads the `AutoTapUnlocked` attribute (architecture 1e, CR-3) once IdleService writes it.
- **Actual:** checks `Rank >= 3` or `AutoClickerOwned` itself. Same result today; drifts if the rule changes.
- **Fix hint:** in sprint 2 (when IdleService lands) replace the body with
  `player:GetAttribute(Attr.AutoTapUnlocked) == true`.

### QA-4 [gameplay] tryFight treats any truthy `auto` as Auto-Mog   S3
- **Found by:** integration-programmer, confirmed by qa.
- **File:** `src/server/Gameplay/BossService.luau:166` (`if not auto and ...`).
- **Expected:** only `auto == true` skips the distance check.
- **Actual:** any truthy value skips it. Not reachable from a client today (the remote handler passes `false`,
  line 192), so not an exploit; a hardening fix before Auto-Mog (sprint 2) calls it.
- **Fix hint:** `if auto ~= true and not zone.isNearBoss(player, bossId) then`.

### QA-5 [gameplay] PetService must refresh M after equip, unequip and delete (CR-c)   S2 (sprint 2)
- **Found by:** integration-programmer (D-032 condition).
- **File:** `src/server/Gameplay/PetService.luau` (not written yet); API at
  `src/server/Gameplay/MultiplierService.luau:228`.
- **Expected:** M changes as soon as the equipped pets change.
- **Actual:** MultiplierService only recomputes on events; nothing tells it about pet changes.
- **Fix hint:** call `MultiplierService.refresh(player)` at the end of each successful equip/unequip/delete.
  Acceptance check for T-0xx PetService in sprint 2.

### QA-9 [world] Server boss range check silently uses layout coordinates when a stage is missing   S3
- **Found by:** qa code review (build 1, nil-guard pass).
- **File:** `src/server/World/ZoneService.luau:239` -> `src/shared/World/MapLayout.luau:282-296`.
- **Steps:** builder mistypes a `BossId` (or forgets the tag) on one stage.
- **Expected:** a clear server warning; nothing crashes.
- **Actual:** nothing crashes (good), but the server measures range to the fallback position from `WORLDS`, so the
  boss can't be fought at its real stage and can be fought at an empty spot, with no log line.
- **Fix hint:** on the server, `warn` once per boss id when `getBossStage` returns nil and the layout fallback is
  used (keep the fallback; the client needs it while streaming).

### QA-10 [gameplay] EconomyConfig Rank 2 still at 2,500 lifetime MP (GDD rev 2 says 1,800)   S3
- **Found by:** qa (D-033 rerun).
- **File:** `src/shared/Gameplay/EconomyConfig.luau:158`.
- **Expected:** `RANKS[2].lifetimeMp = 1800` (GDD 4.8, D-033).
- **Actual:** 2,500, so the game keeps the rev 1 timing (Rank 2 at 5:31 for a 3 taps/s boss-only player). The
  Studio spec "RANKS match GDD 7" fails until it changes.
- **Fix hint:** change the one value; `EconomyConfig.validate()` still passes (ranks stay ascending).

### QA-F6 [gdd] 3 taps/s first-rebirth band starts 2 s after the GDD's own time   S3
- **Found by:** qa (D-033 rerun, `python3 -I tests/sim/timing_sim.py`).
- **Expected:** GDD 4.7 rev 2 band "12:30-15:00 at 3 taps/s" contains the table's 3 taps/s times.
- **Actual:** the table says 12:28 (pod counts), 2 s under 12:30. Only the wording is off.
- **Route:** scenarist: write the band as "12:15-15:00" (or "~12:30-15:00"); qa changes the target to match.

## Closed

### QA-6 [qa] Static checker false positives   S3   (fixed in build 1 check)
- **File:** `tests/static/check_handlers.py`.
- **Was:** the Init-yield regex ran from a one-line `function X:Init() end` into the next function (false FAILs
  on HudController:483 and TapController:118), and `Guard.isIntInRange` / `isShortString` were not recognised
  (false FAILs on TapBatch, RequestBossFight, BuyTool, BuyPod).
- **Fix:** one-line Init bodies are empty; multi-line Init ends at the first column-0 `end`. `Guard.*` calls count
  only after the checker confirms the helper's own body does the check (a lying Guard still FAILs). New selftest
  fixtures cover both. Result on `main`: 0 FAIL, 11 PENDING.

### QA-7 [qa] No test that EconomyConfig boss ids match MapLayout   S3   (added in build 1 check)
- **Fix:** Studio spec `EconomyConfig.spec.luau` "BOSSES ids and worlds match MapLayout.BOSS_IDS" and the
  cloud-runnable twin `tests/static/check_boss_ids.py` (13/13 match; a renamed id is caught).

### QA-F1 [gdd] First rank-up missed 5 min at 3 taps/s   S3   (GDD side fixed by D-033; config tracked as QA-10)
- Sim rerun with rev 2: Rank 2 at 2:47 / 3:16 (5/s) and 3:42 / 4:36 (3/s). All under 5 min.

### QA-F2 [gdd] GDD 4.7 table slower than its own numbers   S3   (fixed by D-033)
- 4.7 now uses the sim times; `GDD_TIMES` and the bands in `timing_sim.py` updated. Leftover wording: QA-F6.

### QA-F3 [gdd] "At 3 taps/s add about 40%" only held for the first win   S3   (fixed by D-033)
- GDD 4 now says "+30-40% in the first 5 min, about +15-25% to the first rebirth".

### QA-F4 [architecture] EconomyConfig field names not in the contract   S3   (fixed by D-032)
- architecture 1c lists every entry type and `TAP_BATCH_MAX`.

### QA-F5 [qa] test.project.json failed to build before `wally install`   S3   (fixed in T-024)
- `Packages`/`ServerPackages` are optional paths; `rojo build test.project.json` passes (rechecked in build 1).
