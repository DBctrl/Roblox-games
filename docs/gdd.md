# Game Design Document v1: "Aura Up!" (working title), mog clicker simulator
_Owned by scenarist. Status: **v1 GDD rev 1, awaiting owner approval (gate 1).** Rev 1 (D-017) answers the lawyer's review (docs/legal.md, D-016): sections marked **(rev 1)** changed and are the only ones the lawyer needs to re-check. Replaces the D-013 twist proposal (owner chose no twist, D-014). Inputs: docs/marketing/brief.md sections 2, 4 and 5, docs/marketing/competitors.md (gaps 1, 2, 3, 6, 7), D-011..D-014. Every price and every odds number is **PROPOSED, needs owner approval**. All numbers live in one config file (`src/shared/Gameplay/EconomyConfig`), so qa can retune without code changes._
_**Rev 2 (D-033, balance pass for QA-F1..F3):** a balance-only change. It touches only parts of sections 4, 4.6, 4.7, 7 and 9, each marked **(rev 2)**, and the new 4.8 table lists every number that changed. Nothing in monetization or prices changed, so the D-021 approval scope is the same._

## 1. Concept (rev 1)
- **One sentence:** Tap to build Mog Points, out-glow silly cartoon bosses for coins, hatch pets, rebirth into a neon second world, and challenge friends to fair, opt-in mog-offs where the loser goes flying.
- **Target player:** ages 9-14, mobile first (about 70% of sessions), parody and meme tone. **Maturity (rev 1):** we design for Minimal, but repeated cartoon ragdolls may get **Mild**. Roblox assigns the label; we answer the questionnaire truthfully (paid random items: yes) and never advertise "Minimal" before it is assigned (legal 3.1, 3.2).
- **Session:** 15-25 min. **Genre:** Simulation / incremental clicker. **Server size:** 12.

### Title (rev 1) (follows D-012: no "+1", "Evolution", "Per Click", "Mog Battle", "Frame Mog", no real names, and no "looksmax" wording anywhere)
- **Working title: "Aura Up!"** Short, unique, and it reads as a glow-up without the word "mog". Low risk per legal 4.1; formal trademark clearance is NEEDS-LAWYER (NL-1) before any ad spend or merch.
- Alternative: **"Main Character Clicker"** (legal 4.3: OK). "Glow-Up Bosses" is **dropped** (clashes with e.l.f.'s Roblox "Glow Up!", legal 4.2).
- "Mog" appears only in the description and tags. Player-facing text, the description and tags never use "looksmax"/"looksmaxxing" (legal 3.3b).

## 2. Genre study (unverified stats, see competitors.md)
| Game | Does well | We take (our own version) | We avoid |
|---|---|---|---|
| +1 Mog Evolution (reference) | Aspiration visible from spawn, 1 R$ entry products, weekly Saturday rhythm | Visible idle-station row, cheap ladder, Saturday events | Unclear first fight, purchase pads on the tutorial path, a HUD that is a wall of buy buttons |
| +1 Looks Per Click | Zones plus rebirth, week-numbered updates | Numbered weekly updates | Weak codes and retention, sharp decay |
| Frame Mog (title not usable) | 71-pet collection gives a long-term chase | Egg/pet chase, kept small (30 pets) | A real person's name |
| Mog or Die | Several stats; defeated NPCs are shown off | Bosses with personality | Body-image stats ("Bodyfat", "Frame"), unclear paid spins |
| Pet simulators (genre-wide) | Egg odds shown on screen, equip slots, hatch animation | Odds UI before every purchase, pity on paid eggs | Trading and scam surface (cut from v1) |

**Our edge:** a first win in under 40 s (gap 1), an avatar that really transforms (gap 2), PvP that paid multipliers cannot buy (gap 3), a parent-friendly tone (gap 6), and comedic ragdoll as the headline (gap 7).

## 3. Core loop
```
TAP (anywhere) --> Mog Points (MP, a power stat, not spent)
      |                     |
      |          MP >= boss threshold --> MOG the boss (3 s) --> COINS (+ boss ragdolls)
      |                                                              |
      |           +--------------------------------------------------+
      |           v
      |   spend coins: TOOLS (MP per tap) | GLOW PODS (idle MP/s) | COIN EGGS (pets = MP multiplier)
      |           |
      +-----------+  faster MP --> stronger bosses --> more coins
                  |
          coins >= rebirth cost --> REBIRTH (reset MP, coins, tools; keep pods, pets, rank)
                  |                  +0.5x MP and +10% coins, permanently
                  v
          Rebirth 3 --> WORLD 2 (stronger bosses, better eggs, new tools and pods)
Side loops: lifetime MP --> RANK-UP (visible cartoon transformation). Opt-in DUELS --> Duel Wins board.
```

## 4. Economy math
**Assumptions for every timing:** manual tapping at 5 taps/s (a fair kid on mobile). **(rev 2)** At 3 taps/s, the first 5 minutes take about 30-40% longer (first win 0:49 vs 0:36, Rank 2 +32% to +41%), but the first rebirth takes only about 15-25% longer (12:28-14:48 vs 10:41-11:46). Coins come from fixed boss rates, not taps, so tap speed matters less once the player is saving coins. Other assumptions: a boss fight cycle of 4 s (3 s mog-off animation plus 1 s), and a server cap of 12 accepted taps/s.

### 4.1 Multiplier formula (server-computed only) (rev 1)
- `MP per tap = ToolPower x M`, `MP/s in a pod = PodRate x M`
- `M = PetMult x RebirthMult x PaidTier x VIP x Boost`
  - `PetMult = min(25, 1 + sum of equipped pet bonuses)` (additive inside, capped at x25)
  - `RebirthMult = 1 + 0.5 x Rebirths` (R1 = x1.5, R10 = x6)
  - `PaidTier` = the highest owned ladder tier only (x1/2/4/8/16/32). Tiers do not stack.
  - `VIP` = x1.25 if owned. `Boost` = x2 while a timed Hype Snack runs, else x1.
- **Sanity bound:** `M` is clamped to **10,000** on the server. Theoretical max at R10 = 25 x 6 x 32 x 1.25 x 2 = 12,000, so the clamp binds only for whales. The clamp rises with each new world.
- `Coins per win = BossCoins x (1 + 0.1 x Rebirths) x (2 if Coin Snack active)`. Pets and paid tiers do **not** touch coins, which keeps the coin economy (rebirth costs, eggs) predictable.
- **(rev 1) Coin Snack is free-only:** it comes only from the daily reward (D5), codes and scripted events. It is never a developer product, never in a bundle and never boosted by VIP. Every term in the coins formula is now unbuyable: `BossCoins` is fixed per boss and `Rebirths` can't be bought (Skip Rebirth is cut, section 8).

### 4.2 Tools (coins; reset on rebirth)
| # | Tool (cartoon) | MP/tap | Cost | World |
|---|---|---|---|---|
| 1 | Pocket Comb | 1 | free | 1 |
| 2 | Hair Gel | 2 | 50 | 1 |
| 3 | Bubble Face Mask | 4 | 400 | 1 |
| 4 | Cool Shades | 8 | 2,000 | 1 |
| 5 | Fresh Kicks | 15 | 7,500 | 1 |
| 6 | Foam Dumbbell | 30 | 25,000 | 1 |
| 7 | Golden Mic | 60 | 80,000 | 1 |
| 8 | Aura Crystal | 120 | 250,000 | 1 |
| 9 | Neon Headphones | 250 | 1,000,000 | 2 |
| 10 | Runway Jacket | 500 | 4,000,000 | 2 |
| 11 | Star Shades | 1,000 | 15,000,000 | 2 |
| 12 | Crown of Drip | 2,000 | 60,000,000 | 2 |

### 4.3 Glow Pods (rev 1) (idle stations, our theme: beauty-salon pods; permanent, kept through rebirth)
Stand inside a pod to earn MP/s with no tapping (tapping still adds on top). Only the pod you stand in counts. **(rev 1) Pods cost coins only.** The Robux early-unlock column is removed, because it waived a coin cost (section 8, rule g).
| # | Pod | Base MP/s | Cost (coins) |
|---|---|---|---|
| 1 | Ring Light Pod | 10 | 250 |
| 2 | Selfie Booth | 40 | 3,000 |
| 3 | Spa Steamer | 150 | 15,000 |
| 4 | Disco Mirror | 500 | 60,000 |
| 5 | Halo Lamp | 1,500 | 200,000 |
| 6 | Neon Tube Pod (W2) | 5,000 | 1,500,000 |
| 7 | Spotlight Stage (W2) | 15,000 | 10,000,000 |

### 4.4 Bosses (MP is a threshold, not spent; repeatable; 4 s cycle)
| World | Boss (fictional cartoon) | MP needed | Coins/win | Coins/s at R0 |
|---|---|---|---|---|
| 1 Glow Town | Sleepy Sid | 100 | 10 | 2.5 |
| 1 | Bedhead Benny | 600 | 30 | 7.5 |
| 1 | Sweatband Sal | 3,000 | 90 | 22.5 |
| 1 | Captain Cardio | 12,000 | 250 | 62.5 |
| 1 | Duke of Drip | 40,000 | 600 | 150 |
| 1 | Glow Queen | 120,000 | 1,500 | 375 |
| 1 | Aura Titan (world boss) | 400,000 | 4,000 | 1,000 |
| 2 Neon Runway | Laser Larry | 500,000 | 10,000 | 2,500 |
| 2 | DJ Dazzle | 1,500,000 | 30,000 | 7,500 |
| 2 | Chrome Champ | 5,000,000 | 80,000 | 20,000 |
| 2 | Runway Rex | 15,000,000 | 200,000 | 50,000 |
| 2 | Diva Supreme | 50,000,000 | 500,000 | 125,000 |
| 2 | King Shine (world boss) | 150,000,000 | 1,200,000 | 300,000 |

If MP is below the threshold, the MOG button is grey and shows "Need 600 MP (you: 412)". There is no lose-fight against bosses, so there is no frustration.

### 4.5 Rebirth (rev 1)
- **Cost:** `15,000 x 3^(n-1)` coins: R1 15K, R2 45K, R3 135K, R4 405K, R5 1.2M, R6 3.6M, R7 10.9M, R8 32.8M, R9 98M, R10 295M. Uncapped after that; R11+ is a soft wall until World 3 (Update 3).
- **Bonus:** +0.5 to RebirthMult and +10% coins per rebirth. **Resets:** MP, coins, tools. **Keeps:** pods, pets, rank and look, paid items, codes.
- **World 2** portal unlocks at **Rebirth 3**. (rev 1: there is no paid skip. Rebirths and the portal can't be bought.) A prompt "REBIRTH READY" pulses when coins reach the cost.

### 4.6 Auto systems (unlockable progression) (rev 1)
- **Auto-Tap (free):** unlocks at Rank 3 (**(rev 2)** ~8-10 min at 5 taps/s, 4.7), 3 taps/s. Paid Auto Clicker = 6 taps/s from the start. Auto and manual taps together are capped at 12/s on the server.
- **Auto-Mog (free):** unlocks at Rebirth 1. It re-fights your strongest beatable boss in the current world every 5 s, even while you sit in a pod (the AFK combo). (rev 1: there is no paid early unlock, because it ran coin-earning fights. Auto-Mog is free only.) Auto-mog never runs in duels.

### 4.7 Simulated timings (free player, life 1, no Robux) (rev 2: times now match the qa sim, docs/qa/timing-sim-sprint1.md)
**(rev 2)** Each time cell gives two cases: "pod counts" means the Ring Light Pod MP/s counts while fighting (the pod is in boss range), and "boss-only" means it never counts. The real map lands between the two. Purchases happen in this order: Hair Gel, Ring Light Pod, Bubble Face Mask, 1 Basic Egg, Cool Shades, then save for Rebirth 1. Every time except Rank 2 is the T-024 sim output for rev 1. Only Rank 2 changed in rev 2, and it changes no later row, because Rank 2 unlocks nothing that speeds up play. The Rank 2 times come from the sim's own MP rates and need a qa sim rerun to confirm (4.8).
| 5 taps/s (pod counts / boss-only) | Event | 3 taps/s (pod counts / boss-only) | Check |
|---|---|---|---|
| 0:00-0:10 | Spawn facing Sleepy Sid, camera pan, "TAP to power up!" | 0:00-0:10 | |
| 0:30 | 100 MP (100 taps) | 0:43 | |
| **0:36** | **First boss win** (MOG button pulses next to Sid). Ragdoll plus a free Starter Fit look piece. +10 coins | 0:49 | < 60 s |
| ~0:53 | 5 Sid wins = 50 coins, arrow to the Tool Stand | ~1:07 | |
| **0:56** | **First upgrade:** Hair Gel (2 MP/tap) | 1:09 | < 2 min |
| 1:42 | Beat Bedhead Benny (600 MP) | 2:27 | |
| **2:06** | **First idle station:** Ring Light Pod (250 coins) | 2:39 | < 3 min |
| **2:48 / 3:16** | **First rank-up (rev 2)** (Rank 2 at **1,800** lifetime MP): full transformation moment | **3:42 / 4:36** | < 5 min at 5 and 3 taps/s |
| 3:03 | Bubble Face Mask (400) | 3:37 | |
| 3:40 / 4:26 | Beat Sweatband Sal | 4:46 / 6:16 | |
| 3:56 / 4:17 | First Basic Egg hatch (500) | 4:50 / 4:51 | |
| 5:30 / 5:54 | Cool Shades | 6:24 / 7:20 | |
| 7:12 / 8:41 | Beat Captain Cardio (62.5 coins/s) | 9:27 / 12:36 | |
| 8:00 / 9:40 | Rank 3, free Auto-Tap unlocks | 10:38 / 14:23 | |
| **10:41 / 11:46** (band **10:30-12:00**, rev 2) | **First rebirth** (15K coins) | 12:28 / 14:48 | ~10-15 min |
| 11:59 / 13:25 | First rebirth if the player also buys Fresh Kicks (7,500) first: it costs about 1:20-1:40, because the coins spent on Kicks are worth more than the extra MP before Rebirth 1 | 14:35 / 16:56 | optional detour, no target |

**(rev 2) First-rebirth band:** we keep the 15,000 Rebirth 1 cost and move the band to the real timing instead (QA-F2 option 1). At 5 taps/s it is **10:30-12:00**, and at 3 taps/s it is 12:30-15:00. Both sit inside the "~10-15 min" check. We keep the cost because a higher one would push a 3 taps/s player who stays at the bosses (14:48) past 15 min.

**Long run (free, no Robux, about 45 min/day; rev 2: not re-simulated yet, qa T-047 confirms):** R2 ~27 min, R3 + World 2 ~40 min, R5 ~1 h 15, **R10 ~4 h**, beating King Shine ~5-6 h of play (about 7-8 days). With the x2 tier, R10 comes about 25% sooner; with x32 + VIP, about 60% sooner. qa confirms these with a sim script in sprint 1 and tunes only EconomyConfig.

**Rev 1 recheck after the monetization changes:**
- **Free player: no change.** Every free coin source (boss wins, daily calendar coins and D5 Coin Snack, codes, duel rewards, events) is untouched, and no cost changed. The table above and the R2/R3/R5/R10/King Shine times stand.
- **Paying player: slightly slower than in v1, and capped.** Robux now buys only MP power (ladder, VIP, Hype Snack, Auto Clicker, pets). Coins still come only from bosses at fixed rates, so paid speed-up has a ceiling. x2 tier is still about 25% sooner to R10. The best case (x32 + VIP + Hype Snack always on + Auto Clicker + top pets) is about 60-65% sooner, **reached through MP only**. In v1 Skip Rebirth and coin packs could cut R10 time without limit; that path is gone.
- **Starter Pack effect:** it used to give 3,000 coins plus the Selfie Booth (worth about 6,000 coins, about 3 min of play at 3:40). It now gives 30 min of Hype Snack plus a +0.30 pet, which is about 2-3 min faster to the first rebirth. Same feel, and no coins.
- **Restricted players** (PolicyService flag): coin eggs stay fully available under option A, so their loop is the same as any free player's.

### 4.8 Rev 2 changes (balance pass for QA-F1, QA-F2, QA-F3; D-033)
**Config changes** (gameplay-programmer updates `src/shared/Gameplay/EconomyConfig.luau`):
| GDD place | EconomyConfig field | Rev 1 | Rev 2 | Why |
|---|---|---|---|---|
| 7, Rank 2 "Comb Rookie" | `RANKS[2].lifetimeMp` | 2,500 | **1,800** | QA-F1: a 3 taps/s player who stays at the bosses reached Rank 2 at 5:31. At 1,800 that player gets there at about 4:36, still 24 s inside the 5-min target if walks run longer than assumed |

No other EconomyConfig value changes. Tools, pods, bosses, rebirth cost (`REBIRTH_BASE_COST` 15,000, `REBIRTH_COST_GROWTH` 3), eggs, caps, auto systems and every Robux price and product stay at rev 1.

**Doc-only changes** (no config field):
| GDD place | Rev 1 | Rev 2 | Finding |
|---|---|---|---|
| 4.7 first rebirth band (5 taps/s) | 12:00-14:00 | 10:30-12:00 (3 taps/s: 12:30-15:00) | QA-F2 |
| 4.7 Rank 2 time (5 taps/s) | 3:40 | 2:48 / 3:16 (3 taps/s: 3:42 / 4:36) | QA-F1 |
| 4.7 other rows | rev 1 estimates (0:38, 1:05, 2:05, 3:05, 4:05/4:30, 6:00, 8:30, ~9:10) | sim times (see table) | QA-F2 |
| 4.7 Fresh Kicks route | "~14 min" | 11:59 / 13:25 | QA-F2 |
| 4 assumptions, 3 taps/s note | "add about 40%" | "+30-40% in the first 5 min, about +15-25% to the first rebirth" | QA-F3 |
| 4.6 Auto-Tap unlock | ~9 min | ~8-10 min | QA-F2 |
| 9 rank-up "WOW" time | ~3:40 | ~2:50-3:15 (3 taps/s ~3:40-4:40) | QA-F1 |

**For qa (qa-owned files, listed here so nothing gets missed):** in `tests/sim/timing_sim.py`, set `GDD_TIMES` to the 4.7 times above. Change the "12:00-14:00" target to (630, 720) s for 10:30-12:00. Regenerate `tests/shared/Fixtures/GddTables.luau` with `--luau-fixture`, because the Rank 2 value changed. Then rerun the sim and confirm the rev 2 Rank 2 times.

## 5. Eggs and pets (rev 1)
- **Equip slots:** 3 at start, +1 at Rebirth 3, +1 at Rebirth 8 (5 free max), +1 with VIP (6). **Inventory cap:** 60 pets, plus a free-player "auto-delete Commons" toggle and multi-delete. Pets follow the player (simple float, no pathfinding).
- Hatching: 1 at a time. Hatch x3 unlocks at Rebirth 2 (free). The hatch animation is about 2 s and can be skipped.
- **Odds are shown on the egg's UI before every purchase** (coin or Robux), as exact percentages, plus pet bonuses and "you own" ticks. Pets give MP bonus only (see 4.1).
- **(rev 1) Coin eggs are free random items (option A, PROPOSED).** No Robux path leads to coins or to a coin-egg hatch (section 8 rule g), so Basic, Shiny, Neon, Runway and the Update 2 Beach Egg are not paid random items. They stay open to every player, including restricted players, and still show their odds.
- **(rev 1) Robux egg odds placement (legal 2.1):** odds sit on the egg UI **and** in the purchase confirmation step, never only on a separate page. If the list doesn't fit, it opens from a button labelled "Odds Info" (never a bare (i) icon). The 3-pack says: "Each of the 3 hatches uses these odds. Pity can trigger inside the pack."
- **Pity (rev 1):** Robux eggs only. Coin eggs have no pity.
  - Rule, written in words on the Robux egg UI and in the confirmation step: **"Every 10th hatch with no Legendary or better is a guaranteed Legendary (90%) or Mythic (10%)."**
  - The counter ("Pity: 7/10") shows on the egg UI and resets on any Legendary or Mythic hit.
  - **True odds:** when the counter is 9/10, the egg UI and the confirmation step replace the base table with the real next-hatch odds: Star Egg = Halo Dragon 90%, Cosmic Unicorn 10%, Starlight Corgi 0%, Aura Lion 0%; Galaxy Egg = Supernova Dragon 90%, Galaxy Kraken 10%, Nebula Fox 0%, Comet Wolf 0%. In a 3-pack that crosses the pity hatch, the UI lists the odds for each of the 3 hatches.
  - The counter is **saved in the profile per egg** (Star, Galaxy, and later the Week 4 egg each get their own) and survives rejoin and rebirth.
- **Region and age rule (rev 1):** the server calls `PolicyService:GetPolicyInfoForPlayerAsync(player)` at PlayerAdded inside `pcall`, retries with backoff, and caches `ArePaidRandomItemsRestricted` for the session. **If the call fails, the player counts as restricted.** The result is replicated as a read-only player attribute used only to hide UI; the server decides everything else. The code reads the flag and never hard-codes countries. (Resolves the earlier TODO(verify-api), per legal 2.4: server calls work for any player.)
  - **Restricted players:** the Star and Galaxy stands show "Robux eggs aren't available on your account" and no buy button.
  - **Restricted player buys anyway** (a stale or client-forced prompt): ProcessReceipt never rolls. It grants a **stated fixed pet** and logs the event: **Star Egg -> Starlight Corgi (+1.00); Galaxy Egg -> Nebula Fox (+3.00)**; a 3-pack grants 3 copies. The same text sits on the restricted stand: "If a purchase still goes through, you get Starlight Corgi (no random roll)." The pity counter doesn't change. Robux is never taken for nothing.
- **Bundles (rev 1, legal 2.6):** no egg hatch, Robux or coin, ever goes into the Starter Pack, VIP or any future pack.

| Egg (world, price) | Pet | Rarity | Bonus | Odds |
|---|---|---|---|---|
| **Basic Egg** (W1, 500 coins) | Puff Pup | Common | +0.05 | 50% |
| | Bubble Bunny | Common | +0.08 | 30% |
| | Glam Hamster | Uncommon | +0.15 | 15% |
| | Shades Gecko | Rare | +0.30 | 4.5% |
| | Mirror Fox | Epic | +0.60 | 0.5% |
| **Shiny Egg** (W1, 10,000 coins) | Spa Panda | Common | +0.20 | 45% |
| | Gel Penguin | Uncommon | +0.35 | 35% |
| | Disco Duck | Rare | +0.60 | 15% |
| | Sparkle Owl | Epic | +1.20 | 4.5% |
| | Golden Glow Cat | Legendary | +3.00 | 0.5% |
| **Star Egg** (W1, Robux, PROPOSED 25 R$ / 3 for 69 R$) | Starlight Corgi | Rare | +1.00 | 60% |
| | Aura Lion | Epic | +1.80 | 30% |
| | Halo Dragon | Legendary | +3.50 | 9% |
| | Cosmic Unicorn | Mythic | +8.00 | 1% |
| **Neon Egg** (W2, 250,000 coins) | Neon Moth | Common | +0.50 | 45% |
| | Laser Lizard | Uncommon | +0.80 | 35% |
| | Runway Raccoon | Rare | +1.30 | 15% |
| | Chrome Shark | Epic | +2.20 | 4.5% |
| | Spotlight Phoenix | Legendary | +5.00 | 0.5% |
| **Runway Egg** (W2, 5,000,000 coins) | Velvet Llama | Common | +1.00 | 45% |
| | Glitter Gorilla | Uncommon | +1.50 | 35% |
| | Hologram Tiger | Rare | +2.50 | 15% |
| | Prism Whale | Epic | +4.00 | 4.5% |
| | Crowned Griffin | Legendary | +8.00 | 0.5% |
| **Galaxy Egg** (W2, Robux, PROPOSED 49 R$ / 3 for 129 R$) | Nebula Fox | Rare | +3.00 | 60% |
| | Comet Wolf | Epic | +5.00 | 30% |
| | Supernova Dragon | Legendary | +9.00 | 9% |
| | Galaxy Kraken | Mythic | +20.00 | 1% |
Each egg sums to 100%.

**Free-player rule (keeps Robux eggs from making free players irrelevant):**
1. Each world's best free pet beats that world's most common Robux pet (Golden Glow Cat +3.0 > Starlight Corgi +1.0; Crowned Griffin +8.0 > Nebula Fox +3.0).
2. PetMult is capped at x25. A typical free team at R10 is x8-12, so paid pets are worth at most ~2-3x free pets, never 10x.
3. Boss thresholds and rebirth costs are tuned to the **zero-Robux** curve (4.7). Paying only goes faster.
4. Pets, the paid tier and VIP have **zero effect in duels** (section 6).

## 6. PvP mog battles (opt-in duels)
- **Start:** tap a player -> "Challenge to a Mog-Off". The target sees Accept/Decline (auto-decline after 10 s). Settings has "Duel requests: On / Off" (default **On only after the tutorial quest chain ends**, ~4 min; before that the player cannot send or receive challenges). Both players are teleported to one of 2 Mog Rings in each world's hub.
- **How a duel is decided:** 3-2-1, then an **8-second tap-off**. `Score = valid taps x (1 + 0.03 x RankEff)`, where `RankEff = min(own rank, opponent rank + 2)`. Max rank edge = +6% against a 2-rank-lower opponent. **Pets, paid tier, VIP, boosts and auto-tap are ignored.** Taps are capped at 10/s per player (it's about effort, not money). Ties go to a draw and both get a light bounce.
- **Payoff:** the winner strikes a pose with a server banner. The loser gets a 2.5 s **cartoon ragdoll knockback** into the ring's foam pit (no damage, no death, no stat loss), then stands up.
- **Free rematch:** both see a Rematch button for 10 s; if both accept, it runs again at once. There is no paid Revenge.
- **Rewards:** winner gets +1 Duel Win (weekly board) and coins = 2 min of their own best-boss coins/s. Rewarded wins are capped at **5 per hour**, and only **2 rewarded wins per same opponent per 15 min** (stops win-trading with alts). Losers lose nothing.
- **Anti-grief:** 15 s challenge cooldown per target; max 1 pending outgoing challenge; per-session block list ("Block challenges from X"); duel request spam (3 declines in a row from the same target) auto-mutes that challenger for 10 min; ragdoll and knockback apply only inside the ring to the two duelists; leaving or disconnecting = forfeit with no reward to anyone.
- **Server validation:** target exists, is in the same server, both are post-tutorial, both have duels On, neither is in a duel or hatching, the cooldowns hold; tap batches (client sends a count every 0.5 s) are clamped to 10/s x elapsed and accepted only inside the 8 s window; score, result, rewards and ragdoll trigger are server-only; rematch needs both accepts within the 10 s window.

## 7. Rank ladder and visible transformation (lifetime MP, never resets) (rev 2: Rank 2 lowered to 1,800)
Every rank-up plays a 3 s moment: spotlight, confetti, camera orbit, the new look pops on, and a server banner "<Name> leveled up to <Rank>!". Looks are **our own cartoon accessories and clothing layered on the player's avatar** (hair, outfit, shades, aura particle). No body-shape edits. Players can toggle "show my own avatar look" off.
| Rank | Name | Lifetime MP | Look change |
|---|---|---|---|
| 1 | Fresh Spawn | 0 | messy cartoon bedhead hat |
| 2 | Comb Rookie | 1,800 | neat hair + clean tee (rev 2: was 2,500) |
| 3 | Glow Starter | 15,000 | faint white aura |
| 4 | Drip Apprentice | 60,000 | hoodie + sneakers glow |
| 5 | Style Scout | 250,000 | cool shades |
| 6 | Main Character | 1,000,000 | jacket + blue aura |
| 7 | Trendsetter | 5,000,000 | sparkle trail |
| 8 | Aura Farmer | 25,000,000 | gold chain-style medal + gold aura |
| 9 | Icon | 100,000,000 | runway outfit |
| 10 | Spotlight Legend | 500,000,000 | personal spotlight beam |
| 11 | Star Mogger | 2,000,000,000 | star halo |
| 12 | Supreme Mogger | 10,000,000,000 | rainbow aura + crown |
The first win also grants a free "Starter Fit" piece so the very first payoff changes the avatar.

## 8. Monetization (rev 1) (developer products only; every price PROPOSED, needs owner approval)
**Headline (rev 1): Robux never buys coins.** 23 products: the "x2 Mog Points" ladder, MP boosts, fixed pets, cosmetics, VIP, a coin-free Starter Pack, 2 Robux eggs and tips. This is legal option A for BLOCKER B-1, as a PROPOSAL. Option B is in section 15.

**Rules:**
- (a) **FirstWin UX gate:** shop buttons stay hidden until the first boss win, and the client won't open a prompt before it. This is a UX gate only. **ProcessReceipt always delivers a valid paid receipt**, even one bought before FirstWin (legal 2.10).
- (b) **No purchase touch pads at all in v1.** World shop stands are ProximityPrompts that open the shop UI, never a purchase prompt, and none sit on the tutorial path.
- (c) The Starter Pack pop-up shows once, after the first rank-up.
- (d) Permanent items are dev products saved as entitlements in the profile and re-granted on join. Each listing says "Permanent". ProcessReceipt is idempotent (receipt ids stored).
- (e) **(rev 1) Ladder:** the shop shows **only the next tier up** as buyable. Owned and lower tiers are hidden. Every ladder listing says **"Does not stack: the highest tier you own applies."** Products are named **"x2 Mog Points"**, "x4 Mog Points", and so on, never "x2 money/earnings/coins" (this applies in the shop, product names and marketing). If a receipt arrives for a tier that is owned or below the owned tier, the server grants the **next unowned tier** instead. If the player owns x32, it adds Hype Snack time instead: 10 min per 2 R$ paid, ignoring the 2 h cap for this grant. Either way the event is logged.
- (f) Odds and the pity rule are shown on every Robux egg before purchase and in the confirmation step (section 5).
- (g) **(rev 1) The coin firewall:** no product, bundle, pass, or VIP perk may grant coins, multiply coins, waive or discount a coin cost, grant something the coin shop sells (tools, pods, rebirths, portals), or grant an egg hatch. That covers both direct and indirect paths. Robux may buy only **MP power** (ladder, VIP MP, Hype Snack, Auto Clicker, fixed or Robux-egg pets), **convenience that doesn't touch coins** (walk speed), **cosmetics**, and **tips**. MP raises which boss a player can beat, but coins per win stay fixed per boss and can't be bought (4.1). qa adds a test that walks every product's grant function and fails if any of them touches coins, coin-shop items, rebirth count or egg hatches.
- (h) **(rev 1) Timed boosts (legal 2.14):** the HUD shows time left and the 2 h cap. Purchase is blocked once the cap would be exceeded, so no paid time is wasted. Boost time runs **only while the player is in game** (offline time doesn't use it up). This is stated in the listing.
- (i) **(rev 1) Wording (legal 2.16, 2.17):** cosmetics are called "Exclusive" (not "Limited"), with no timers and no "rare/resale" claims. Every tip listing says: "Thank-you banner + donor name-tag colour. No other in-game benefit."

| Category | Product | Price (R$) PROPOSED, needs owner approval | Effect |
|---|---|---|---|
| Multiplier ladder (permanent, next tier only) | x2 / x4 / x8 / x16 / x32 Mog Points | 4 / 8 / 19 / 39 / 79 | PaidTier in 4.1, MP only, PvE only. "Does not stack: the highest tier you own applies." |
| Cheap entry (timed) | Hype Snack | 2 | x2 MP for 10 min (stacks to 2 h, in-game time only) |
| | Speed Sneakers | 4 | +50% walk speed for 30 min (in-game time only) |
| Automation | Auto Clicker | 39 | 6 auto taps/s from the start (MP only; 12/s server cap) |
| **Fixed pets (rev 1, no randomness)** | Ring Light Retriever (one copy) | 29 | Fixed pet, +1.00 MP bonus. Below Golden Glow Cat (+3.0), the best free W1 pet |
| | Neon Pup (one copy) | 59 | Fixed pet, +3.00 MP bonus. Below Crowned Griffin (+8.0), the best free W2 pet |
| Exclusive cosmetic per world | Golden Glow Fit (W1) / Neon Icon Fit (W2) | 249 / 349 | outfit + aura, cosmetic only, no stats |
| VIP (permanent) (rev 1) | VIP | 99 | x1.25 MP, +1 pet slot, gold name tag, **VIP Sparkle Aura cosmetic, +10 min Hype Snack on each daily-reward claim**. VIP never changes coin rewards or egg rewards |
| Starter pack (once) (rev 1) | Starter Pack | 9 | **30 min Hype Snack + Sparkle Pup fixed pet (+0.30) + Rookie Shades cosmetic.** No coins, no pod, no egg |
| Robux eggs | Star Egg 1 / 3 | 25 / 69 | table 5, pity 10 (saved), restricted fallback: Starlight Corgi |
| | Galaxy Egg 1 / 3 | 49 / 129 | table 5, pity 10 (saved), restricted fallback: Nebula Fox |
| Donations (D-002) | Tip 5 / 25 / 100 / 500 / 1,000 | 5 / 25 / 100 / 500 / 1,000 | thank-you banner + donor name-tag colour, nothing else; Top Donors board shows names and rank only, no amounts, with opt-out (D-008) |

Total: **23 products** (v1 had 34).

**Removed in rev 1, and why (each was a Robux-to-coins path):**
| Removed | Path it opened |
|---|---|
| Coin Pouch / Bag / Vault | Direct coins |
| Coin Snack (paid) | Coin multiplier. It stays as a **free-only** reward (daily D5, codes, events) |
| Starter Pack 3,000 coins + Selfie Booth | Direct coins, plus a coin-shop item, which frees up coins |
| VIP "daily reward coins x2" | Coin multiplier |
| Glow Pod early unlocks 2-7 | Waived a coin cost, so the saved coins could go to eggs |
| Skip Rebirth | Waived a coin cost and added +10% coins permanently |
| Skip to World 2 | Bought coin-gated access to richer bosses and W2 coin eggs |
| Auto-Mog Early | A paid way to run boss fights (coin income) while AFK. Free Auto-Mog still unlocks at Rebirth 1 |

**Not sold:** coins in any form, anything that affects duels, a paid rematch, MP packs, pet slots alone, egg hatches inside any bundle, trading.

## 9. First 5 minutes (second by second)
- **0-5 s:** spawn in Glow Town plaza; camera pans 2 s to Sleepy Sid snoozing on a small stage 15 studs away; big pulsing text "TAP to power up!" plus a hand icon. No shop buttons visible. The leaderboard is collapsed.
- **5-30 s:** every tap pops "+1" sparkles and a meter "100 MP to beat Sleepy Sid" fills. The floor arrow lights the path. Sid yawns at 50%.
- **30-38 s:** meter full -> "GO MOG HIM!" arrow; walk ~3 s; the giant MOG button pulses; 3 s pose-off (Sid tries a pose, fails comically). **First win at ~38 s:** Sid ragdolls off the stage into a foam pit, +10 coins burst, the avatar gets the Starter Fit with a pop. Quest line: "Win 5 more for Hair Gel (1/5)".
- **38-65 s:** farm Sid; at 50 coins the Tool Stand glows; buy Hair Gel; tap numbers double (+2). Shop/Robux buttons appear in the HUD now (small, bottom-right, not blinking).
- **65-125 s:** quest "Beat Bedhead Benny (600 MP)" -> win ~1:42 -> quest "Unlock the Ring Light Pod" -> stand in it at ~2:05; "+10/s" floats up while the player idles.
- **2:05-3:15 (rev 2):** quest "Buy Bubble Face Mask" (~3:03). Rank meter in HUD.
- **~2:50-3:15 WOW (rev 2; at 3 taps/s ~3:40-4:40):** Rank 2 "Comb Rookie" (1,800 lifetime MP): spotlight, camera orbit, new hair + tee, server banner, nearby players see it.
- **3:15-5:00 (rev 2):** Starter Pack pop-up (once, closable); quest "Hatch your first pet" (Basic Egg at ~4:00-4:20, odds shown); duels unlock, "Challenge someone!" tooltip on the leaderboard.
- **Come back tomorrow:** the Day 1 daily reward is claimed with a visible Day 2-7 calendar (Day 7 = exclusive aura), "Auto-Mog unlocks at your first rebirth" teaser, Saturday event countdown on the hub billboard.

## 10. Social and retention (rev 1)
- **Leaderboards:** global (OrderedDataStore) Lifetime MP, Rebirths, Weekly Duel Wins (reset Saturday 00:00 UTC), plus in-server leaderstats (Rank, Rebirths). Hub podium shows the top 3 Lifetime MP looks.
- **Daily reward (7-day calendar), free only:** D1 2 min best-boss coins, D2 Hype Snack 10 min, D3 5 min coins, D4 free Basic/Neon Egg hatch (best world unlocked), D5 Coin Snack 15 min, D6 10 min coins, D7 exclusive "Week Streak Aura" cosmetic (kept forever) + 15 min coins. Missing a day restarts at D1. **(rev 1)** VIP adds only +10 min Hype Snack per claim. No paid item changes a daily coin or egg reward.
- **Codes (rev 1):** launch code `AURAUP` (500 coins + 10 min Hype Snack). Milestone codes are published at 1K / 10K / 50K likes and 1M visits (boosts and coins only), posted in the game description and group, and are the same for everyone. **Wording rule (legal 2.9):** in-game and in the description we say only "New codes at like and visit milestones". We never say "Like the game to get a code" or "Like + favorite for rewards", and never claim to detect likes. Rewards never require proof of liking or favoriting.
- **Group (rev 1, legal 2.8):** the reward is the cosmetic-only **Crew Cap** + chat tag, with no stats and no gameplay value. The button text is exactly: **"Join our group for update news + a free Crew Cap"**. It is never shown with, next to, or bundled with any like/favorite message. Membership is checked on the server with `Player:IsInGroup` when the player joins and when they press "Claim". Before launch, the owner or team-lead reads the live Community Standards in a browser. If any rule forbids it, we ship the fallback: the button gives news only, with no reward. D-008's ban on a gameplay reward stands.
- **Analytics events:** time to first win, first upgrade, first pod, first rank-up, first rebirth, session length, duel count, every purchase. **(rev 1)** Also log restricted-player Robux receipts and ladder fallback grants. Everything is keyed by UserId only, with no names or free text (legal 5.3).

## 11. Content rules compliance (rev 1) (brief section 5; legal section 3)
- Upgrades are cartoon only: combs, gel, face masks, shades, sneakers, foam dumbbells, mics, crystals, outfits, auras. **No** self-injury, bone-smashing, starving, steroids, surgery, pills, body-fat or height mechanics, or body-shape edits.
- Ranks and bosses are positive or silly. No "Subhuman"-style insults. Loser text is "Out-glowed! Rematch?", never insults about looks.
- **(rev 1) Bosses lose to style, never to their bodies (legal 3.3a):** no "fat" or "skinny" losers, no "ugly" face reveals, and no jawline, height or weight labels or gags. Every boss's joke is an outfit, a prop or a personality: Sleepy Sid yawns and has pillow hair, Bedhead Benny's hair is a mess, Sweatband Sal's sweatband slips over his eyes, and Captain Cardio's whistle and too-big tracksuit flap around (no muscle or weight jokes). Boss gags are also free of fart and burp humour (legal 3.2). The builder's asset brief repeats these rules.
- **(rev 1) Wording:** no "looksmax"/"looksmaxxing" anywhere: UI, quests, product names, description, tags, badges. No real-world tips, diets or exercise claims (legal 3.3d).
- No real people's names or likenesses. All bosses are invented cartoons. Nothing copied from competitors (names, labels, UI, art, red/green split face). The Rank 8 name "Aura Farmer" is fine, but no animation, thumbnail or ad recreates the viral dance, outfit or likeness (legal 3.5). Competitor titles never appear in the description, tags or ad keywords (legal 4.4).
- Maturity: we design for Minimal (no blood, no realistic violence; ragdoll is a cartoon bounce into foam; no romance; no chat features beyond default Roblox chat). Repeated ragdolls may get **Mild**, so we answer the questionnaire truthfully and redo it when an update changes an answer.
- Paid random items (Star and Galaxy eggs only, rev 1): odds and the pity rule are shown before purchase and in the confirmation step, true next-hatch odds are shown at pity, the server checks PolicyService, restricted players get a fixed pet, and there is no trading. They are declared in the questionnaire.

## 12. v1 scope (rev 1) (3 weeks + 1 buffer; 4 programmers + builder)
| Week | Ships |
|---|---|
| 1 | Tapping + MP, tools 1-8, W1 bosses 1-7 with MOG fight + boss ragdoll, coins, tutorial quest chain, HUD, ProfileStore saves, EconomyConfig + qa sim script, **server PolicyService check + cached attribute (rev 1)** |
| 2 | Glow Pods 1-5, rebirth, Auto-Tap/Auto-Mog, eggs/pets W1 (odds UI, **saved per-egg pity + true next-hatch odds + pity rule text + restricted fixed-pet fallback (rev 1)**, equip, inventory), rank ladder + 12 looks + rank-up moment, dev products + ProcessReceipt (**next-tier-only ladder + fallback grant, fixed pets, boost cap UI (rev 1)**), leaderboards |
| 3 | Duels (rings, tap-off, ragdoll, rematch, anti-grief), World 2 (6 bosses, tools 9-12, pods 6-7, 3 eggs), daily reward, codes, donations board, group Crew Cap (IsInGroup), analytics, mobile perf pass |
| 4 | Buffer: balance from qa sim, exploit tests, purchase-flow tests (**incl. the coin-firewall test from 8g and restricted-player receipts, rev 1**), owner playtest fixes |
Rev 1 scope check: 11 fewer products to wire and test (coin packs, pod unlocks, skips, Auto-Mog Early, Coin Snack) roughly offsets the added pity, policy and fallback work. Net scope is about the same.

Builder: Glow Town hub + boss stage row + pod row + 2 Mog Rings + egg stands; Neon Runway World 2; 13 boss models, 30 pet models (+3 fixed pets: Sparkle Pup, Ring Light Retriever and Neon Pup, made as recolours plus an accessory on existing pet models), 12 look sets, 2 exclusive fits, Crew Cap, VIP Sparkle Aura (own or free-licensed, logged).

**Not in v1:** any Robux-for-coins product (coin packs, paid Coin Snack, pod early unlocks, Skip Rebirth, Skip to World 2, Auto-Mog Early; rev 1); trading; pet fusing/golden/shiny variants; ranked ELO; a second prestige (Ascend); Worlds 3-4; co-op bosses and squads (D-013 option C); runway slot choice (D-013 option A); live "admin abuse" events run by a person; MP packs; teleport-to-stage products; premium x99/x999 pods; Mogger mega pack; potions inventory; pet enchants; friend-referral rewards; Discord links; quests beyond the tutorial chain; pets with abilities.

## 13. Live-ops: weekly Saturday update + event (rev 1) (scripted server events by UTC clock, no admin needed)
Rev 1 rules for every update: event coin boosts are free and server-wide, and never sold or extended with Robux. New coin eggs stay free random items, which means no product may ever sell coins (8g). Any new Robux egg gets odds in the UI and confirmation step, the written pity rule, its own saved pity counter, true next-hatch odds, a stated fixed-pet fallback for restricted players, and a questionnaire re-check. Update 2's Beach Egg is a coin egg, free to all, and shows its real end date (no fake timers). The Update 1 code is posted with the same "New codes at like and visit milestones" wording rule.
| Week | Saturday update (fits 1 week) | Event (Sat 16:00-18:00 UTC, PROPOSED) |
|---|---|---|
| 1 | Update 1 "Glow Weekend": balance fixes from data, 2 new rank-look variants, code `GLOWWEEK`, first weekly Duel board reset | Server-wide x2 coins for 2 h + "Duel Champ" crown (cosmetic, 1 week) for the weekly #1 |
| 2 | Update 2 "Beach Glow": limited coin-only Beach Egg (5 pets, W1 power band, 7 days, odds shown), beach pod skin | "Boss Rush": every boss gives x2 coins and a confetti ragdoll for 2 h |
| 3 | Update 3 "Duel Season 1": weekly duel ladder with cosmetic tier badges (Bronze-Gold), 2 more Mog Ring arenas, duel emotes (free, earned) | "Mog-Off Hour": duel coin reward cap raised from 5 to 10 per hour |
| 4 | Update 4 "World 3: Star Studio" (builder starts the map in week 3; code is data-only in EconomyConfig): 5 bosses, 2 tools, 1 pod, 1 coin egg + 1 Robux egg (odds, pity), rebirth soft wall moved to R15, M clamp raised | World 3 opening party: x2 MP for everyone for 2 h + launch code |

## 14. Launch and compliance risks (rev 1)
| # | Risk | Impact | Plan |
|---|---|---|---|
| R-1 | **Kids/Select 16+ trial period** (legal 3.6). To reach players under 16, the game must pass Roblox's evaluation. The creator account must be age-checked with 2-Step Verification on. There is a one-time refundable per-game fee (about 1,000 R$, unverified) **or** Roblox Plus/Premium held for at least 2 months. Then a **trial visible only to age-checked users 16+** runs until 250 unique plays by highly engaged, age-checked users within 60 days, plus a safety review. | **At launch, our 9-14 target audience can't see the game.** First-week data (retention, purchases) will come from 16+ players and won't match the target. The weekly update rhythm (section 13) may start before the real audience arrives. | The owner starts the creator age check and 2SV now. The fee is a Robux spend (gate 3, owner decides). Marketer plans the first players and any ads for a 16+ audience (older siblings, meme-clicker fans). Updates 1-2 can slip without harm. We don't judge fun or monetization from trial-phase data alone. |
| R-2 | Maturity label comes back **Mild**, not Minimal (legal 3.1) | Low: both reach Kids and Select | Never promise "Minimal" in marketing until the label is assigned |
| R-3 | Group reward is later found to break Community Standards (legal 2.8) | Low | Switch the button to news-only (config flag) |
| R-4 | Title clearance (legal NL-1, AURAUP Class 5 application) | Medium for ads and merch | Formal clearance before any ad spend; "Main Character Clicker" is the fallback |
| R-5 | The paid MP ladder still lets payers beat richer bosses sooner, which is an indirect link between Robux and coin income | Low: coins per win stay fixed and can't be bought, and the lawyer's option A treats this as compliant | Lawyer re-checks rule 8g. If the lawyer rules otherwise, fall back to option B |

## 15. Open questions for the owner (via team-lead) (rev 1)
1. **BLOCKER B-1, pick A or B (monetization gate):**
   - **A, proposed in this GDD:** Robux never buys coins (section 8 rule g, 23 products). All coin eggs are free random items, open to everyone, with odds shown. Lost revenue: coin packs, pod unlocks and skips.
   - **B, the alternative:** keep the v1 coin products (coin packs, paid Coin Snack, Starter Pack coins, VIP daily coins x2, pod unlocks, skips). Every coin egg then counts as a paid random item. When `ArePaidRandomItemsRestricted` is true, coin eggs are blocked for that player, and they get a **non-random path to pets**: a coin Pet Shop that sells each coin-egg pet at an expected-value price, or a fixed hatch order shown on the egg. B adds about 1 day of work plus qa. Restricted players (a large share of a 9-14 audience: UK, Australia, Brazil and growing) get a different, more shop-like loop. The coin shop must show the real coin amount for that player before purchase (legal 2.13).
2. **Prices and odds:** approve or change every PROPOSED price in section 8 (including the new fixed pets at 29 and 59 R$, and the new VIP and Starter Pack contents) and every odds row in section 5.
3. **Robux eggs:** confirm them for v1 despite D-002 (D-014 says yes), with saved pity at 10, PolicyService gating and the fixed-pet fallback (Starlight Corgi / Nebula Fox).
4. **Ladder top:** stop at x32 (79 R$) or at x16 (39 R$)? A lower top keeps the free/paid PvE gap smaller.
5. **VIP +1 pet slot:** keep it (a mild PvE edge) or make VIP cosmetic + MP only?
6. **Title:** "Aura Up!" (pending clearance, NL-1) or "Main Character Clicker"? "Glow-Up Bosses" is dropped.
7. **Event time:** Saturday 16:00-18:00 UTC. Is that right for your audience and your availability?
8. **Group reward:** the cosmetic Crew Cap (allowed as RISK, subject to your pre-launch read of Community Standards), or no reward?
9. **Kids/Select:** pay the refundable fee (Robux, gate 3) or rely on a Plus/Premium membership held for 2+ months? When can you complete the creator age check and 2SV?
10. **Rank names:** keep "Star Mogger"/"Supreme Mogger", or switch now to "Star Icon"/"Supreme Icon", which the lawyer called safer for Select review?
