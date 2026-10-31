# QA bugs and findings
_Owned by qa. project-manager copies open items into docs/backlog.md. Severity: S1 crash/data loss/exploit,
S2 broken feature, S3 polish. Findings (QA-F) are design/doc issues, not code bugs; they go to the named role._

## Open

### QA-F1 [gdd] First rank-up misses 5 min at 3 taps/s when pods do not count during fights   S3
- **Found by:** T-024 timing sim (`docs/qa/timing-sim-sprint1.md`).
- **Steps:** `python3 -I tests/sim/timing_sim.py`; read the "3/s boss-only" column.
- **Expected:** GDD 4.7 check "first rank-up < 5 min" (and GDD 9 "~3:40 WOW") holds for a slower kid too.
- **Actual:** Rank 2 at 5:31 when the player stands at the boss stage instead of in the Ring Light Pod
  (4:14 if the pod counts while fighting; 3:15-3:51 at 5 taps/s).
- **Route:** scenarist (lower Rank 2 to about 2,000 lifetime MP, or accept) and builder (place the Ring Light Pod
  within `INTERACT_RANGE` of Bedhead Benny's stage so the pod and the fight overlap). Decision needed, not a code fix.

### QA-F2 [gdd] GDD 4.7 table is slower than its own numbers at 5 taps/s; first rebirth lands before 12:00   S3
- **Found by:** T-024 timing sim.
- **Expected:** first rebirth 12:00-14:00 at 5 taps/s (GDD 4.7, T-024 criterion).
- **Actual:** 10:41 (pod+boss) and 11:46 (boss-only) with the 4.7 purchase order; Rank 2 3:15 vs 3:40, Captain
  Cardio 7:12 vs 8:30. Only the "+Fresh Kicks" route lands in the band (11:59 / 13:25), and the GDD says that route
  takes ~14 min. Still inside the check column "~10-15 min", so nothing is broken.
- **Route:** scenarist: either update the 4.7 table to the sim times, or retune (for example a higher Rebirth 1
  cost) as an `EconomyConfig` value change. qa reruns T-047 after any change.

### QA-F3 [gdd] "At 3 taps/s add about 40%" holds only for the first win   S3
- **Found by:** T-024 timing sim.
- **Actual:** first win +36% (0:49 vs 0:36), but first rebirth only +17% (12:28 vs 10:41, pod+boss), because coins
  come from fixed boss rates, not taps. Rank 2 at 3/s is +30% to +43%.
- **Route:** scenarist: reword GDD 4 assumptions ("+40% early, about +15-25% to the first rebirth").

### QA-F4 [architecture] EconomyConfig entry field names and BOSSES shape are not in the contract   S3
- **Found by:** T-024 test writing.
- **Expected:** docs/architecture.md 1c names the fields other folders read: tool `power`/`cost`/`world`, pod
  `rate`/`cost`, boss `id`/`need`/`coins`/`world` (and whether `BOSSES` is an array or a map by id), rank
  `lifetimeMp`. ShopService, BossService, IdleService, the UI and qa all depend on them.
- **Actual:** only the table names are listed; `TAP_BATCH_MAX` (30, section 2 #1) is also missing from the 1c
  surface.
- **Workaround:** `EconomyConfig.spec.luau` accepts common field names via `TestKit.field`.
- **Route:** integration-programmer (contract request, after T-006 lands so it documents what exists).

### QA-F5 [qa] test.project.json failed to build before `wally install`   S3   (fixed in T-024)
- **Actual (before):** `rojo build test.project.json` errors: `File $path: Packages` could not be turned into an
  instance, because Packages/ServerPackages do not exist until wally runs (none in the cloud session).
- **Fix:** both are now `{ "optional": ... }` paths, like `default.project.json`. The tests use their own
  `tests/shared/TestKit.luau` instead of TestEZ, so they need no package. Builds clean with rojo 7.4.4.

## Closed
(none)
