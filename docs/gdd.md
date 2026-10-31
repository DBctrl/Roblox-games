# Game Design Document: Candy Factory Tycoon (working title)
_Owned by scenarist. Sections: see .claude/agents/scenarist.md. Status: DRAFT, needs owner approval (D-007)._

## 1. Concept
- **One sentence:** Claim a candy factory plot, buy droppers that pump out candy, watch it ride conveyors into
  the seller, upgrade the machines, then rebirth for a permanent earnings boost and do it all again faster.
- **Target player:** ages 9-14 (Roblox "All ages"/9+ content, no violence, no chat-dependent mechanics).
- **Session length:** 15-30 min (one rebirth early on, then 1-2 rebirths per session). Idle-friendly: income keeps
  flowing while the player stands on their plot.
- **Genre:** button-path tycoon (droppers + conveyor + seller) with prestige (rebirth).
- **Server:** 6 players, 6 plots around a central hub.

## 2. Genre study (mechanics only; nothing copied)
| Game | What it does well | What we take |
|---|---|---|
| Miner's Haven | Droppers -> conveyors -> furnace that sells; ore value raised by upgraders on the line; rebirth resets for rarer gear | The dropper/conveyor/seller visual loop; rebirth as the long-term goal |
| Restaurant Tycoon 2 | Constant small purchases, visible growth of your building, strong day-to-day retention | A purchase available every ~1 min early; daily reward |
| Retail Tycoon 2 | Clear income-per-second feedback, satisfying number growth, friends visiting each other's stores | Big readable $/s on HUD; plots visible to other players |
| Theme Park Tycoon 2 | Your base is a showcase; social pride drives play time | Plots face the hub so everyone sees your factory grow |
| Classic "button-path" tycoons (many, e.g. hero/mansion tycoons) | Walk onto glowing pads in a fixed order; zero learning curve; the next button is always visible | Fixed-order buy pads, only the next 2 shown, so a new player never needs a tutorial |

Lessons: (1) the first purchase must happen in under a minute; (2) the player must *see* money being made
(objects moving to a seller); (3) prestige must make the second run feel noticeably faster; (4) cheap,
non-random monetization works best when it speeds up what the player already does.

## 3. Core loop
```
 droppers make candy --> conveyor carries it --> seller turns it into Cash ($)
        ^                                                    |
        |                                                    v
 rebirth (+50% forever) <-- hit rebirth cost <-- buy next dropper / machine upgrade
        |                                                    |
        +----------- faster income, same path again <--------+
```
Action (stand on plot, walk to next pad) -> reward (Cash/s ticks up) -> upgrade (dropper or upgrade)
-> faster action (next pad affordable sooner). Outer loop: rebirth resets the plot, keeps a permanent boost.

**Simulation rule (for programmers):** income is computed on the server per dropper tick
(`value x multipliers` every `interval`). Candy on the conveyor is a **client-side visual only**
(physics-programmer), so there are no physical parts for exploiters to touch and no server physics load.

## 4. First 5 minutes
| Time | What happens |
|---|---|
| 0 s | Spawn in the candy hub. Arrow + glowing gates on the 6 plots. Text: "Walk into a gate to claim a factory!" |
| ~8 s | Player touches a free plot gate -> plot claimed, name sign shows their name. (Auto-claim the nearest free plot at 20 s if they haven't.) |
| ~10 s | Free **Gumdrop Dropper** is already running; first gumdrop rides the conveyor (3 s travel). |
| ~13 s | First candy hits the seller: "+$5" pop, coin sound, Cash counter ticks. **First reward < 15 s.** |
| ~45 s | Start cash $50 + 2.5 $/s reaches $150 -> **Jellybean Dropper** pad turns green. **First upgrade < 60 s.** |
| ~2 min | **Lollipop Dropper** ($750): first big machine, giant swirl spins, candy colours mix on the belt. |
| ~4 min | **"Wow" moment:** **Candy Cane Dropper** ($2,500) drops striped canes with a whistle; the belt is now visibly busy, and a new pad appears by the seller: **Faster Gears** ("speed up every machine"), the next goal (~8 min). |
| ~5 min | Rebirth bar on HUD shows "Rebirth at $6M: +50% earnings forever". Daily reward popup: "Come back tomorrow for Day 2 (x2 reward)". |

Reasons to return tomorrow: 7-day daily streak (section 7), unfinished rebirth progress (saved), leaderboard rank.

## 5. Progression
**Currency:** one soft currency, **Cash ($)**. Display with suffixes (K, M, B, T). No premium currency.

**Income formula (server):**
`$/s = sum(dropper value / interval) x GlazeMult x RebirthMult x PassMult`
- `interval` = 2.0 s base, reduced by Faster Gears. `RebirthMult = 1 + 0.5 x rebirths`.
- `PassMult` = highest owned multiplier pass (section 6), else 1.
- Start cash on a fresh run: $50.

**Droppers** (fixed order, one pad each; buying a dropper reveals the next pad):
| # | Dropper | Cost | Value/candy | $/s (base 2.0 s) | Cumulative $/s | Wait at base* |
|---|---|---|---|---|---|---|
| 1 | Gumdrop | free | 5 | 2.5 | 2.5 | - |
| 2 | Jellybean | 150 | 12 | 6 | 8.5 | 40 s |
| 3 | Lollipop | 750 | 30 | 15 | 23.5 | 88 s |
| 4 | Candy Cane | 2,500 | 70 | 35 | 58.5 | 106 s |
| 5 | Chocolate Bar | 8,000 | 160 | 80 | 138.5 | 137 s |
| 6 | Caramel Swirl | 22,000 | 360 | 180 | 318.5 | 159 s |
| 7 | Cotton Candy | 60,000 | 800 | 400 | 718.5 | 188 s |
| 8 | Rainbow Taffy | 160,000 | 1,800 | 900 | 1,618.5 | 223 s |
| 9 | Mega Gummy | 420,000 | 4,000 | 2,000 | 3,618.5 | 260 s |
| 10 | Golden Truffle | 1,100,000 | 9,000 | 4,500 | 8,118.5 | 304 s |
\*Wait with droppers only, no upgrades, no rebirth, no pass. Upgrades shorten the later waits.

**Machine upgrades** (separate pads near the seller, appear once the listed dropper is owned):
| Upgrade | Level 1 | Level 2 | Level 3 | Effect (L1 / L2 / L3) | Appears after |
|---|---|---|---|---|---|
| Faster Gears | $12,000 | $100,000 | $700,000 | interval 1.6 s / 1.33 s / 1.0 s (x1.25 / x1.5 / x2 speed) | Dropper 4 |
| Sugar Glaze | $35,000 | $300,000 | $1,800,000 | candy value x1.5 / x2 / x3 | Dropper 5 |
Fully upgraded plot with no rebirth: 8,118.5 x 2 x 3 = **48,711 $/s**.

**Rebirth:** button on the plot's seller, enabled when Cash >= cost. Resets Cash, droppers and machine upgrades.
Keeps rebirth count, passes, daily streak, stats. Each rebirth gives **+50% earnings (additive)**.
`RebirthCost(n) = 6,000,000 x 2^(n-1)` for the n-th rebirth. Uncapped.

| Rebirth # | Cost | Mult after | Est. time for this run (no pass)** | Cumulative |
|---|---|---|---|---|
| 1 | 6M | x1.5 | 24 min | 24 min |
| 2 | 12M | x2.0 | 17 min | 41 min |
| 3 | 24M | x2.5 | 15 min | 56 min |
| 4 | 48M | x3.0 | 15 min | 1.2 h |
| 5 | 96M | x3.5 | 18 min | 1.5 h |
| 6 | 192M | x4.0 | 25 min | 1.9 h |
| 7 | 384M | x4.5 | 38 min | 2.6 h |
| 8 | 768M | x5.0 | 63 min | 3.6 h |
| 9 | 1.536B | x5.5 | 110 min | 5.4 h |
| 10 | 3.072B | x6.0 | 195 min | 8.7 h |
\*\*From a greedy idle simulation (cheapest purchase first, ignores walking). Real play ~10-20% slower.

**Target time-to-complete v1:** Rebirth 10 ("Candy Tycoon" title badge) in ~9-10 h for a free player, about
2-3 play weeks at 30-45 min/day. Rebirths beyond 10 continue for leaderboards. With the x2 pass: ~4.5 h;
x4: ~2.2 h; x8: ~1.1 h; x16: ~35 min (see balance note in section 6). Constants live in one config module
(`src/shared/Gameplay/EconomyConfig`) so balancing never needs code changes.

## 6. Monetization (owner direction D-002)
**All prices: PROPOSED, needs owner approval.** Roblox keeps ~30% of each sale, so a 4 R$ pass nets ~2-3 R$.
No paid random items, no loot boxes, no premium currency, no pay-to-skip-rebirth in v1.

### 6a. Money-multiplier ladder: **game passes** (permanent)
| Tier | Effect | Price | Status |
|---|---|---|---|
| Candy x2 | x2 all earnings | 4 R$ | PROPOSED, needs owner approval |
| Candy x4 | x4 all earnings | 8 R$ | PROPOSED, needs owner approval |
| Candy x8 | x8 all earnings | 16 R$ | PROPOSED, needs owner approval |
| Candy x16 | x16 all earnings | 32 R$ | PROPOSED, needs owner approval |

- **Pass vs product: game pass.** "x2 earnings" reads as a permanent upgrade; a pass is bought once, survives
  rebirth and server hops, is checked with `MarketplaceService:UserOwnsGamePassAsync`, needs no receipt or
  DataStore bookkeeping, and can't be lost by a save bug. A consumable dev product would need timers or
  durations and feels worse to players at these prices.
- **Stacking: the highest owned tier applies, no multiplicative stacking.** Owning x2 + x4 gives x4, not x8.
  This keeps the cap at x16 and the economy predictable. Shop UI shows all tiers, marks owned ones, labels
  each tier "replaces lower tiers", and highlights the next tier. Buying any tier directly is allowed.
- **Applies to:** all Cash income (stacks multiplicatively with rebirth and Sugar Glaze). Not to daily reward.
- **Balance note:** x16 lets a buyer reach Rebirth 10 in ~35 min. Doubling rebirth costs keep later rebirths
  meaningful, but the global Rebirths leaderboard will be dominated by pass owners (open question Q3).
  We stop at x16 for v1; an x32 for 64 R$ is in the open questions, not in v1.
- Also check in-game purchases with `MarketplaceService.PromptGamePassPurchaseFinished` so the boost applies
  instantly without rejoining.

### 6b. Donations: **developer products** (repeatable)
| Product | Price | Reward (no gameplay advantage) | Status |
|---|---|---|---|
| Donate Small | 5 R$ | Thank-you toast + confetti on own plot | PROPOSED, needs owner approval |
| Donate Medium | 25 R$ | Above + adds to "Top Donors" board | PROPOSED, needs owner approval |
| Donate Large | 100 R$ | Above + server-wide thank-you message | PROPOSED, needs owner approval |
| Donate Huge | 500 R$ | Above + golden sparkle on plot sign for the session | PROPOSED, needs owner approval |
| Donate Mega | 1,000 R$ | Above + candy fireworks over the hub | PROPOSED, needs owner approval |
- Granted via `MarketplaceService.ProcessReceipt`, idempotent by `PurchaseId`, donated total saved to
  DataStore before returning `PurchaseGranted`.
- Donate menu says plainly: "Donations support the developer and give no in-game advantage."

### 6c. Other passes
None in v1. Candidates for later (all need owner approval): Auto-Rebirth toggle, VIP chat tag, extra
plot theme colours. Never: random crates, paid luck, paid cash packs in v1.

## 7. Social and retention
- **In-server leaderstats:** Cash, Rebirths.
- **Global leaderboards** (physical boards in the hub, OrderedDataStore, refresh every 60 s): Most Rebirths,
  Total Cash Earned (lifetime), Top Donors (R$ donated).
- **Daily reward** (7-day streak, claim once per UTC day, streak resets after 48 h without a claim):
  Day 1-6 = Cash equal to 60 s / 90 s / 2 min / 3 min / 4 min / 5 min of the player's current base $/s
  (min $100); Day 7 = 10 min of income + "Sweet Streak" plot sign glow. Scales with progress, never
  multiplied by passes.
- **Visible plots:** all factories face the hub; other players can walk in and watch (no griefing:
  only the owner can press pads; other players' collisions with pads do nothing).
- **Group reward:** +10% earnings for members of the studio's Roblox group (checked with
  `Player:IsInGroup`). Pending lawyer confirmation that it fits current Roblox rules.
- **No rewards for likes, favourites or ratings** (avoid incentivized engagement).
- **Badges** (free to create within Roblox's limits, else cut to 3): Welcome, First Rebirth, Rebirth 5, Rebirth 10.

## 8. v1 scope (3 weeks target, 4 weeks max)
| Owner | v1 work |
|---|---|
| world-programmer | 6 plots, claim gate + auto-claim, ownership, release/reset plot on leave, fixed-order pad reveal |
| gameplay-programmer | EconomyConfig, server income tick, dropper/upgrade purchases (server validated), rebirth, daily reward, multiplier application |
| physics-programmer | client candy visuals on conveyors, dropper animations, seller pop, purchase/upgrade/rebirth effects, candy pooling (max ~40 visual candies per plot) |
| systems-programmer | DataStore save/load (autosave 60 s + on leave + BindToClose), HUD ($, $/s, rebirth bar), shop UI (passes + donations), ProcessReceipt, pass checks, global leaderboards |
| builder | candy hub, 1 plot template x6, 10 dropper models, 2 upgrade machines, seller, 3 leaderboard boards, spawn |

v1 content: 10 droppers, 2 upgrade lines x3 levels, uncapped rebirth, 4 multiplier passes, 5 donation
products, daily streak, 3 leaderboards, 4 badges, 6-player servers, PC + mobile + tablet UI.

**Not in v1:** offline/away earnings; second floor or plot expansion; free-placement building; pets,
crates, eggs or anything random; trading; quests/missions; events or seasonal content; Auto-Rebirth
pass; VIP pass; extra multiplier tiers above x16; rebirth shop or rebirth tokens; plot customization/
themes; friend-in-server bonus; codes system; console-specific UI polish; localisation beyond English;
anti-AFK kicks or AFK rewards; NPC customers; sounds beyond a small free/owned SFX set.

## 9. Update roadmap (each fits 1 week)
1. **Update 1 "Second Floor":** plot expansion unlocked at Rebirth 3: 5 new droppers (values 20K-400K),
   1 new upgrade line (Candy Press, x1.5/x2/x3), stairs + elevator pad. Codes system for launch codes.
2. **Update 2 "Sweet Dreams":** offline earnings (25% of base $/s, max 4 h, shown on rejoin);
   friend bonus (+5% per friend in server, max +20%); quest board with 3 daily quests paying Cash.
3. **Update 3 "Factory Style":** rebirth tokens (1 per rebirth) spent in a Rebirth Shop on plot
   themes/colours and small permanent perks (e.g. +10% Glaze); first seasonal candy decoration set.
   Possible Auto-Rebirth pass (needs owner approval).

## 10. Open questions for the owner
1. Approve the multiplier ladder prices (4 / 8 / 16 / 32 R$) and the "highest tier applies" rule?
2. Add an x32 tier for 64 R$ now, later, or never? (It makes Rebirth 10 reachable in ~18 min.)
3. Should global leaderboards be split or annotated for pass owners, or is pass dominance acceptable?
4. Approve donation tiers (5 / 25 / 100 / 500 / 1,000 R$) and their cosmetic thank-you rewards?
5. Keep the +10% group bonus (pending lawyer check), and do you already have a Roblox group?
6. Title "Candy Factory Tycoon" is generic; OK to keep, or prefer something more brandable?
7. Is 9-14 the right audience, and is ~24 min to the first rebirth the pace you want?
