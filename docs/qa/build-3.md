# Build 3 (sprint 3 merge)
_Build note from **integration-programmer**'s sprint-3 merge summary. The guard-write hook blocks that role from
`docs/qa/`, so qa wrote it here on 2026-10-31 from team-lead's hand-off, then added the fix-round results and the
review verdict._

**Build:** `main` at `4a0ad26` plus the sprint-3 fix-round 1 commits on `prog/qa/sprint-3` (`40c863c`, `fa196fc`,
`a3bcdc5`, and the commit that adds this note).
**Scope:** code only, static checks only. No Studio run, no map change, no Luau type check (same rule as builds 1-2,
D-022).

## 1. Merge (integration summary)
- All 5 sprint-3 branches merged into `main` with `--no-ff`: world `86d81c8`, gameplay `c746588`, physics
  `230a1c5`, systems `61e76df`, qa `1f1df78`. Then T-072 `4a0ad26` (contracts, T-071 listing text, architecture v1.5).
- Contracts and decision renumbering: D-069, `docs/architecture.md` v1.5 section 8.
- All checks passed except `check_grants.py` (5 false FAILs, fixed below).
- Cross-module calls match the contracts (integration's check).

## 2. Fix round 1 (qa)
| Commit | Change |
|---|---|
| `40c863c` T-081 | `check_grants.py` flags only **writes** to coins / toolIndex / podsMask / rebirths / world2Unlocked / coinSec (`=`, `+=`..., `rawset`) and coin-writing calls. Reads such as `PetService.slotsFor` (`data.rebirths`) pass. A kind-dispatch helper (`MultiplierService.setSec`, which names `coinSec`) is excused only when every caller in the grant chain passes a literal `"Hype"`/`"Speed"`. Selftest still FAILs a real `data.coins += 500` and a `setSec(.., "Coin", ..)` call (checked with the yield removed too). |
| `fa196fc` T-068 | `DailyReward.spec`: adapters over `Gameplay/Util/DailyMath` (`claim`, `utcDay`) and `EconomyConfig.DAILY_REWARDS`; live layer probes `RewardService.claim`. `Duel.spec`: adapters over `Gameplay/Util/DuelMath` (`pruneRewardLog` + `rewardAllowed`, as `payWinner` runs them; `acceptTaps` with a `TapState` per call). |
| `a3bcdc5` T-046 | Golden Glow Cat fixture bonus 3.00 -> 3.20 (D-060, owner Q11) in `tests/shared/Fixtures/GddEggs.luau` and `GddTables.luau`. |
| docs | `bugs.md`: QA-12, QA-F10, QA-F12 closed; QA-13, QA-14 filed. |

Note: `src/shared/Gameplay/EconomyConfig.luau:261` on `4a0ad26` still says Golden Glow Cat `bonus = 3.00`. The
PetRoll / EconomyConfig Studio specs will FAIL that row until gameplay's 3.20 change is merged.

## 3. Results
| Check | Result |
|---|---|
| StyLua `--check` src + tests | PASS |
| Selene src + tests | 0 errors, 0 warnings |
| `rojo build default.project.json`, `test.project.json` | PASS |
| `check_handlers.py` | 0 fail, 1 pending (RedeemCode, Update 2 by design), 16 C->S remotes |
| `check_authority.py` | 0 fail, 0 pending |
| `check_boss_ids.py` | 0 fail, 13 bosses |
| `check_duel.py` | 0 fail, 0 pending |
| `check_grants.py` | 0 fail, 2 pending (Entitlement, Donation: MonetizationService puts them in its registry directly in `Init`, not through `registerGrant`; both read in review, no coin path) |
| Selftests | handlers 5 fail / 12 pending, authority 3 fail, duel 9 fail, grants 5 fail / 2 pending: all as documented |
| `timing_sim.py` | all PASS (first rebirth 10:41 / 11:46 at 5/s, 12:28 (D-052 tolerance) / 14:48 at 3/s) |

Not checked: anything that needs Studio (Studio specs, exploit pass with real remotes, DataStore/receipt runs,
device emulation, performance).

## 4. S1 review (sprint-3 code)
- **Lost or duplicated purchases:** none found. `MonetizationService` is the only `ProcessReceipt`; in-server
  `inFlight` dedupe; `profile.receipts` checked before and inside the one `DataService.update`
  (`PurchaseRules.applyGrant`, grant on a deep copy, merged with the PurchaseId together); `PurchaseGranted` only
  after `saveAndConfirm` sees the id; every error path answers `NotProcessedYet`. A full inventory refuses the grant
  (receipt retried on rejoin), never drops it. QA-F11's partial-grant case is solved by the copy.
- **Robux-to-coins:** none. Runtime firewall (`PurchaseRules.firewallBreach` on coins, toolIndex, podsMask,
  rebirths, world2Unlocked) plus the static check; Entitlement and Donation grants write only flags and
  `stats.robuxDonated`; paid boosts add Hype time only; daily VIP perk is Hype only.
- **Duel exploits:** none at S1. Taps go through `TapService` then `DuelMath.acceptTaps` (10/s, 80 total, window
  plus 0.5 s grace); score is `EconomyConfig.duelScore(taps, ranks)` only; forfeit pays nobody; reward caps
  5/hour and 2 per opponent per 15 min are stored in the profile. QA-13 (S3): clock skew drops future log rows.
- **Daily double-claim:** none. Day from server `os.time()`, re-checked inside the `DataService.update` that
  writes `lastClaimDay`, so two claims on one UTC day cannot both pass; a slower server refuses.
- New: QA-13, QA-14 (both S3). Open S1: none. Earlier S2s still listed open (QA-1, QA-2, QA-8, QA-5) look
  fixed in the code on `4a0ad26` (`GameData.luau:397-400`, `:369`, `BossService.luau:124-125`,
  `PetService.luau:402/449`); qa closes them after a Studio check. QA-F11 and QA-F13 likewise look done (D-069).

## 5. Verdict
**SHIP-TO-OWNER** for the static build: no S1, no new S2. Studio specs and the receipt/DataStore pass still need a
Studio build before `/playtest`.
