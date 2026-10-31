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
- **Fix hint:** change the one value; `EconomyConfig.validate()` still passes (ranks stay ascending). Planned as T-088 (D-035).

### QA-11 [systems] Corrupt schemaVersion below 1 throws in migrate and strands the player   S3
- **Found by:** qa code review (T-046, sprint 2). Test: `tests/server/Specs/Persistence.spec.luau`
  "migrate does not throw on a corrupt version below 1".
- **File:** `src/server/Data/Util/ProfileSchema.luau:122-137` (`migrate`), caller `src/server/Data/DataService.luau:183`.
- **Steps:** a save with `schemaVersion = 0` (or -1, or 0.5) loads; `migrate` loops `while version < 1`, finds no
  `MIGRATIONS[0]` and the `assert` throws.
- **Expected:** treated as v1 like a missing/NaN version (the comment at line 126 says "corrupt field: treat as v1").
- **Actual:** `load()` errors in its spawned thread after the lock is taken: no `DataLoaded`, no kick, the session
  stays locked and autosaves. Only reachable through a corrupt record (no client path), so S3.
- **Fix hint:** treat any version that is not an integer >= 1 as 1:
  `if type(version) ~= "number" or version ~= version or version < 1 or version % 1 ~= 0 then version = 1 end`.

### QA-13 [gameplay] Duel reward log drops future-dated entries, so server clock skew lowers the cap count   S3 (sprint 3)
- **Found by:** qa (sprint-3 fix round 1, `Duel.spec.luau` now runs against `DuelMath`).
- **File:** `src/server/Gameplay/Util/DuelMath.luau:82` (`pruneRewardLog` keeps a row only if `row.t <= nowUnix`),
  used by `DuelService.luau:318-320` (`payWinner`).
- **Steps:** win 2 rewarded duels against an alt on server A, both hop to server B whose `os.time()` is a few
  seconds behind A, win again at once.
- **Expected:** the 2 rows still count (the QA-F13 rule: a future-dated entry counts against the caps).
- **Actual:** both rows are pruned as "future", so the third win against the same alt is rewarded. The gain is
  bounded by the skew (seconds) and the 5 per hour cap, hence S3, not an exploit worth S1.
- **Fix hint:** in `pruneRewardLog` drop only rows older than the window (`nowUnix - row.t <
  DUEL_REWARD_WINDOW_SEC`), and clamp a future `t` to `nowUnix` instead of dropping it.
- **Test:** `Duel.spec.luau` "a log entry from the future (clock skew) still counts against the cap" FAILs until then.

### QA-14 [gameplay] Robux egg grant fires HatchResult and `Hatched` even when the receipt is not committed   S3 (sprint 3)
- **Found by:** qa (sprint-3 fix round 1 review).
- **File:** `src/server/Gameplay/PetService.luau:608-619` (inside `grantRobuxEgg`, before `return true`).
- **Steps:** a Robux egg receipt whose grant returns true but whose `DataService.update` does not commit (profile
  released mid-receipt, or a `Firewall:` refusal in `PurchaseRules.applyGrant`).
- **Expected:** a grant fn has no side effects until the commit (D-069 CR-G6: grant fns run on a copy and stay
  side-effect-free).
- **Actual:** the `task.defer` still sends the hatch result (pets the player does not get) and fires
  `PetService.Hatched`, which QuestService counts as a hatch step. The retry then fires them again. No pet or
  Robux is lost or duplicated: the profile is correct.
- **Fix hint:** emit these after the commit, as MonetizationService already does for `RestrictedEggGrant`
  (e.g. a post-commit hook per grant kind), or check `ProfileSchema.hasReceipt` in the deferred fn.

### QA-F7 [gameplay] No pure roll helper, so the 100,000-roll test can't reach the real roller   S3 (sprint 2)
- **Found by:** qa (T-046). Architecture 1b/4b list no roll function; `tryHatch` needs a Player, coins and the
  60-pet cap, so 100,000 rolls through it are not possible.
- **Ask:** T-028 puts the weighted pick in `src/server/Gameplay/Util/PetRoll.luau` as
  `PetRoll.pick(pets: { EggPet }, rng: Random): PetId` (pure, no profile access) and PetService uses it with its
  one server `Random`. Gameplay-internal helper, so no Contract request is needed.
- **Test waiting on it:** `tests/server/Specs/PetRoll.spec.luau` (also accepts `PetService.rollPet(eggId, rng)`);
  SKIPs until then. The reference-roller and odds-vs-GDD checks already run.
- **Fold into:** T-028 acceptance ("roll through a pure `Util/PetRoll.pick`").

### QA-F8 [gameplay] Equip/unequip/delete have no server-callable entry, so QA-5 is only checked statically   S3 (sprint 2)
- **Found by:** qa (T-046). Architecture 1b lists only the `EquipPet`/`DeletePets` remote handlers.
- **Ask:** the handlers call `PetService.setEquipped(player, petUid, equip): (boolean, string?)` and
  `PetService.deletePets(player, petUids): (boolean, string?)` after the argument checks. Public, so
  integration-programmer adds both to architecture 1b (Contract request from gameplay).
- **Tests:** `tests/server/Specs/PetEquip.spec.luau` (Play mode: counts `MultiplierService.refresh` calls and
  checks M = 1 + bonus) SKIPs until then. `python3 -I tests/static/check_authority.py` checks QA-5 statically
  now (PENDING until PetService exists; `--strict` makes it fail).

### QA-F11 [systems] A grant that writes and then fails leaves a partial grant, and the retry repeats it   S2 (sprint 3)
- **Found by:** qa (T-081). `DataService.update` keeps changes made before an error (`DataService.luau:316-318`,
  "Changes made before an error stay applied"). Architecture 3c step 4 says a false grant records nothing, but the
  grant fn has already written to the live `data`.
- **Steps:** a grant fn adds a pet, then errors (or returns false) on a later line. ProcessReceipt answers
  NotProcessedYet with no PurchaseId saved, Roblox retries, and the pet is added again on every retry.
- **Expected:** a failed or refused grant changes nothing (one purchase, one grant).
- **Fix hint:** in ProcessReceipt step 4, run the grant on `ProfileSchema.deepCopy(data)`; if it returns true,
  copy the changed top-level fields back and add the receipt in the same `update`. On false or error, drop the copy.
- **Test:** `Purchase.spec.luau` "grant writes then fails: the partial write is rolled back (QA-F11)".

### QA-F9 [systems] MonetizationService has no test entry, and every product id is 0, so receipts can't be driven   S3 (sprint 3)
- **Found by:** qa (T-081). `ProcessReceipt` is a write-only callback, the grant registry is private, and
  `byProductId(0)` is nil, so ProcessReceipt can't grant anything in Studio until the owner adds the 15 ids.
- **Ask (Contract request through systems, architecture 1b):**
  `MonetizationService.processReceipt(receiptInfo)` (the fn assigned to ProcessReceipt),
  `MonetizationService.grantEntry(player, entry, purchaseId)` (steps 2, 4, 5 for a catalog entry; `processReceipt`
  = steps 1 and 3 plus this), `MonetizationService.getGrant(kind)`. Call `DataService.saveAndConfirm` and
  `Deps.compliance()` through the module table at call time, so qa can inject a save failure or a restricted player.
- **Tests waiting on it:** `Purchase.spec.luau` (dedupe, grant false or throw, save failure, absent player, before
  FirstWin, D-019 ladder, boost cap, restricted and allowed Robux eggs) and `GrantFirewall.spec.luau` (all 23 grant
  fns on a profile copy). Both SKIP until then. `ProductCatalog.spec.luau` and `check_grants.py` run now.

### QA-F13 [gameplay] Duel and daily reward rules have no server-callable or pure entry   S3 (sprint 3, T-049/T-050/T-052)
- **Found by:** qa (T-068). Architecture 1b gives DuelService only `isInDuel` and RewardService no functions, so
  the caps, tap clamp, claim-twice and clock-skew rules can only be reached from a client remote.
- **Ask (gameplay-internal helpers, as with `Util/PetRoll` in QA-F7; the public ones go to integration as a CR):**
  - `Gameplay/Util/DuelRules.rewardAllowed(rewardLog, now, oppUserId): boolean` and
    `DuelRules.acceptTaps(count, now, lastAccepted, activeStart, activeEnd, total): number` (pure).
  - `Gameplay/Util/DailyCalendar.claim(daily, nowUnix): (boolean, newDaily?)` and
    `DailyCalendar.reward(day, bestCoinsPerSec, vip)` (pure).
  - Public: `DuelService.challenge(player, targetUserId)`, `respond(player, challengerUserId, accept)`,
    `rematch(player, accept)`, and `RewardService.claimDaily(player)`; each remote handler calls one of them after
    its type checks.
- **Rules the tests pin (please confirm or tell qa):** a `rewardLog` entry with a future time (clock skew between
  servers) still counts against the caps. A claim on a server whose clock is behind `lastClaimDay` is refused and
  never lowers `lastClaimDay` or resets the streak. Rematches have no count cap of their own: the 2-per-opponent
  per 15 min reward cap is what limits a rematch loop (GDD 6).
- **Tests:** `Duel.spec.luau`, `DailyReward.spec.luau` (SKIP until then). `python3 -I tests/static/check_duel.py`
  checks forfeit on leave, ring release, the reward caps, self-duel, tap clamp, no pet/paid/boost reads, and the
  daily claim's server clock and VIP rule now (PENDING until the services exist).

## Closed

### QA-F10 [architecture] `NotYetProcessed` is not a Roblox enum item   S2   (closed in sprint 3 fix round 1)
- architecture 3c says `NotProcessedYet` (D-069); `MonetizationService.luau` uses `Enum.ProductPurchaseDecision.NotProcessedYet`
  everywhere and `check_grants.py` finds no `NotYetProcessed` in src (PASS). Leftovers, text only: backlog T-056
  criterion (`docs/backlog.md:384`, project-manager) and a comment at `src/server/Gameplay/Util/Deps.luau:56`.

### QA-12 [gameplay] EconomyConfig put the Galaxy Egg in World 2   S3   (closed in sprint 3 fix round 1)
- `EconomyConfig.luau:323` now has `GalaxyEgg.world = 1` (D-057/D-058), odds unchanged.

### QA-F12 [gameplay] `EconomyConfig.duelScore` was missing   S3   (closed in sprint 3 fix round 1)
- `EconomyConfig.duelScore(taps, ownRank, oppRank)` exists (`EconomyConfig.luau:425`) and DuelService scores only
  through it (`DuelService.luau:346-347`). `Duel.spec.luau` checks the formula and the 3-parameter arity.

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

### QA-F6 [gdd] 3 taps/s first-rebirth band starts 2 s after the GDD's own time   S3   (closed by D-052)
- No GDD change. `timing_sim.py` passes two-sided bands within ±15 s of either edge (`BAND_TOLERANCE`), so
  12:28 against 12:30-15:00 now reads "PASS (within 15 s of edge, D-052)". "< X" caps stay strict.

### QA-F2 [gdd] GDD 4.7 table slower than its own numbers   S3   (fixed by D-033)
- 4.7 now uses the sim times; `GDD_TIMES` and the bands in `timing_sim.py` updated. Leftover wording: QA-F6.

### QA-F3 [gdd] "At 3 taps/s add about 40%" only held for the first win   S3   (fixed by D-033)
- GDD 4 now says "+30-40% in the first 5 min, about +15-25% to the first rebirth".

### QA-F4 [architecture] EconomyConfig field names not in the contract   S3   (fixed by D-032)
- architecture 1c lists every entry type and `TAP_BATCH_MAX`.

### QA-F5 [qa] test.project.json failed to build before `wally install`   S3   (fixed in T-024)
- `Packages`/`ServerPackages` are optional paths; `rojo build test.project.json` passes (rechecked in build 1).
