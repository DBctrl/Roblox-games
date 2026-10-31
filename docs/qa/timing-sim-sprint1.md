# Timing sim, sprint 1 (T-024)
_Owned by qa. 2026-10-31. Source: `tests/sim/timing_sim.py` (Python 3, standard library only), run from the repo root:
`python3 -I tests/sim/timing_sim.py --markdown`. Every balance number is parsed from `docs/gdd.md` (4.2 tools,
4.3 pods, 4.4 bosses, 4.5 rebirth cost, 5 Basic Egg odds, 7 ranks), so a GDD retune re-runs without code edits.
This sim reads the GDD, not `EconomyConfig`: T-006 is not merged yet. The Studio test
`tests/server/Specs/EconomyConfig.spec.luau` checks that `EconomyConfig` equals the same GDD tables, so the two
together cover "config = GDD = timings". Not a fun judgement: timings only._

## Model and assumptions
- Free player, life 1 (no rebirth), no Robux, PvE in World 1. M = 1 + Basic Egg expected pet bonus (+0.088).
- Tapping starts after the 10 s spawn pan, at 5 or 3 taps/s, and continues while walking and fighting
  (MP is a threshold, not spent). Server cap 12 taps/s. Free Auto-Tap (+3/s) from Rank 3.
- Fights: strongest beatable World 1 boss, 4 s cycle (3 s fight + 1 s), coins at the end of the cycle,
  3 s walk to each new boss (GDD 9).
- Purchases in the GDD 4.7 order: Hair Gel, Ring Light Pod, Bubble Face Mask, 1 Basic Egg, Cool Shades; then save
  for Rebirth 1 (15,000 coins). Variant "+Fresh Kicks" also buys Fresh Kicks (7,500) first. Each purchase costs
  an assumed 5 s walk.
- Pod scenarios, because the map layout is not built yet: **pod+boss** = pod MP/s counts all the time (pod within
  boss range, an upper bound); **boss-only** = pod MP/s never counts (player always at a boss stage).

## Results (m:ss)
| Event | GDD 4.7 | 5/s pod+boss | 5/s pod+boss +Kicks | 5/s boss-only | 5/s boss-only +Kicks | 3/s pod+boss | 3/s pod+boss +Kicks | 3/s boss-only | 3/s boss-only +Kicks |
|---|---|---|---|---|---|---|---|---|---|
| First boss win | 0:38 | 0:36 | 0:36 | 0:36 | 0:36 | 0:49 | 0:49 | 0:49 | 0:49 |
| Hair Gel | 1:05 | 0:56 | 0:56 | 0:56 | 0:56 | 1:09 | 1:09 | 1:09 | 1:09 |
| Beat Bedhead Benny | 1:42 | 1:42 | 1:42 | 1:42 | 1:42 | 2:27 | 2:27 | 2:27 | 2:27 |
| Ring Light Pod | 2:05 | 2:06 | 2:06 | 2:06 | 2:06 | 2:39 | 2:39 | 2:39 | 2:39 |
| Bubble Face Mask | 3:05 | 3:03 | 3:03 | 3:03 | 3:03 | 3:37 | 3:37 | 3:37 | 3:37 |
| Rank 2 | 3:40 | 3:15 | 3:15 | 3:51 | 3:51 | 4:14 | 4:14 | 5:31 | 5:31 |
| Beat Sweatband Sal | 4:05 | 3:40 | 3:40 | 4:26 | 4:26 | 4:46 | 4:46 | 6:16 | 6:16 |
| First Basic Egg | 4:30 | 3:56 | 3:56 | 4:17 | 4:17 | 4:50 | 4:50 | 4:51 | 4:51 |
| Cool Shades | 6:00 | 5:30 | 5:30 | 5:54 | 5:54 | 6:24 | 6:24 | 7:20 | 7:20 |
| Beat Captain Cardio | 8:30 | 7:12 | 7:12 | 8:41 | 8:41 | 9:27 | 9:27 | 12:36 | 12:36 |
| Rank 3 (Auto-Tap) | 9:10 | 8:00 | 8:00 | 9:40 | 9:40 | 10:38 | 10:33 | 14:23 | 13:37 |
| Fresh Kicks | - | - | 8:40 | - | 9:46 | - | 10:28 | - | 12:47 |
| **First rebirth** | 12:00-14:00 | **10:41** | 11:59 | **11:46** | 13:25 | 12:28 | 14:35 | 14:48 | 16:56 |

## Targets (GDD 4.7 check column; 4.7 order)
| Target | 5/s pod+boss | 5/s boss-only | 3/s pod+boss | 3/s boss-only |
|---|---|---|---|---|
| First boss win < 60 s (3/s: ~0:50) | PASS 0:36 | PASS 0:36 | PASS 0:49 | PASS 0:49 |
| First upgrade < 2 min | PASS 0:56 | PASS 0:56 | PASS 1:09 | PASS 1:09 |
| First idle station < 3 min | PASS 2:06 | PASS 2:06 | PASS 2:39 | PASS 2:39 |
| First rank-up < 5 min | PASS 3:15 | PASS 3:51 | PASS 4:14 | **FAIL 5:31** |
| First rebirth ~10-15 min (check column) | PASS 10:41 | PASS 11:46 | PASS 12:28 | PASS 14:48 |
| First rebirth 12:00-14:00 (4.7 row, T-024 criterion) | **FAIL 10:41** | **FAIL 11:46** | PASS 12:28 | **FAIL 14:48** |

All first-5-minute targets pass at 5 taps/s. At 3 taps/s the first rank-up misses 5 min when the pod does not
count while fighting. Findings QA-F1 to QA-F3 in `docs/qa/bugs.md` go back to scenarist (GDD 4.7) and builder (pod
placement). Long-run checks (R2, R3 + World 2, R10) are T-047 in sprint 2, after pods, rebirth and pets exist.
