# GAME BRIEF: Looksmaxxing clicker simulator (working title: TBD by marketer + scenarist)
_Owner brief, received 2026-10-31. Replaces the Candy Factory Tycoon dry run._

## 1. Reference game, verified Oct 31, 2026
"+1 Mog Evolution" by Navoj Mog (Roblox universe 10764479526, place 92648272637932).
- Launched Aug 30, 2026. ~43.8M visits, 443K favorites, ~98% like rating (337K up / 6.8K down), ~1.6K concurrent players on a Saturday morning.
- 12-player servers, maturity "Minimal" (all ages), genre Simulation -> Incremental Simulator.
- Weekly numbered updates + a Saturday "Admin Abuse" live event with sign-ups (Update 7 on Nov 7).
- Marketing: thumbnails and event images use a split before/after face (ugly face on red vs chad face on green). The trailer opens with the idle-station ("treadmill") feature.

### Core loop
Click -> Appeal -> upgrade hammer -> mog NPC opponents for Wins -> Ascend / Rebirth for multipliers -> Worlds 1-4 -> leaderboard with a meme rank ladder.
Idle layer: "treadmills", stations that earn Appeal automatically, from x1 up to x999, unlocked with Wins.
PvP mog battles with a paid "Revenge" rematch. Ranked mode exists.

### Monetization: NO game passes, 50 developer products (repeatable impulse buys)
- Power multiplier ladder: x1.5 (1 R$), x2 (2), x4 (5), x8 (12), x16 (19), x32 (29), x64 (49), x128 (79), x256 (199)
- Currency packs: +100K Appeal (49), +1M (149), +10M (299), +100M (499)
- Early unlocks of idle stations: x2 (9), x3 (19), x5 (39), x8 (79), x9 (69), x12 (99), x18 (129); premium x99 (249) and x999 (999)
- Skips: Skip Rebirth (39), Skip Ascend (29), Skip to World 2/3/4 (349/749/999), Teleport to stage (2/5/9)
- A limited cosmetic character per world (399 each), VIP (99), Starter Pack (9), Mogger Pack (99), Auto Clicker (39), x2 Wins (49), 2x Win Pad (49), Revenge (49), speed popups (4 / 19), plus hammer upgrades (29 / 79)

### First 5 minutes (played Oct 31, 2026)
- Spawn: rank label above head ("Subhuman", 0 Appeal). The only guidance is one quest line "Get Your First Win! (0/1)" plus big floor arrows. No text tutorial.
- +1 Appeal per click, anywhere. The same click fills a Level bar (L1 = 96, L2 = 100). The first NPC opponent requires 100 Appeal: ~100 clicks / 1.5-2 min.
- The HUD sells from second one: a permanent bottom row of +100K / +1M / +10M Appeal buttons, a "Free Auto Clicker" toggle next to a paid "OP Auto Clicker", and a Starter Pack button.
- Aspiration visible from spawn: a full row of idle stations (x1 -> x18, then premium x99 / x999), a VIP-only x10 station, and a statue showcasing the 399 R$ limited character.
- Purchase pads sit ON the tutorial path: walking over "+4 Wins - Touch to Claim!" instantly opens a Robux purchase prompt.
- Social pressure: the leaderboard is always open (top players with 11-12 rebirths and 20M+ Appeal). Clicking a player shows their stats and a Trade button locked until the tutorial is done.
- Arena: a corridor with "...to unlock!" signage, a red carpet with pads, and NPCs labeled with rank + required Appeal.
- WEAKNESS: it's unclear how to trigger the first mog. A new player can walk around for minutes without getting a win.

### Other competitors (the genre is crowded)
+1 Mog Per Click, +1 Mog Battle, +1 Animal Mog Evolution, Mog or Die, Looksmax and Mog, Frame Mog Clavicular Simulator, +1 Looks Per Click.

## 2. Goal
Ship a playable v1 in 2-4 weeks. Keep the proven loop and monetization structure, but add ONE clear twist players can see in the thumbnail and explain in one sentence. Then grow through weekly Saturday updates.

## 3. Step 1: research and differentiation (scenarist + marketer)
- Study the reference and the competitors: Roblox pages, YouTube/TikTok gameplay, first 5 minutes, update cadence, thumbnails, icons, titles.
- Write /docs/marketing/competitors.md: what each does well and badly, and gaps nobody fills.
- Propose 3 twist options (for example a stronger social/PvP layer, a funnier visible avatar transformation as you rank up, or a co-op/team mog mode). For each: a one-sentence pitch, a thumbnail idea and the build cost.
- STOP and let me pick one.

## 4. Step 2: GDD (scenarist), after I pick the twist
v1 scope only:
- Click -> stat -> upgrade tool -> mog NPCs for Wins -> idle stations -> Rebirth -> 2 worlds -> leaderboard.
- Our OWN rank ladder, item names, idle-station theme, UI and art. Do not copy the reference's names, labels, text or visuals.
- Auto-click and auto-mog as unlockable progression.
- A visible avatar transformation as players rank up. This is the core payoff and the thumbnail.
- Mog battles with funny ragdoll knockback for the loser (physics-programmer), plus a rematch option.
- Monetization modeled on the reference structure, using developer products: cheap entry items (1-9 R$), a multiplier ladder, currency packs, early unlocks, skips, a limited cosmetic per world, VIP, a starter pack and an auto clicker. Balance it so free players can still progress, and Ranked/PvP isn't pure pay-to-win.
- Live-ops: a weekly Saturday update + event. List the first 4 weeks of content.
- Retention: daily rewards, milestone codes (likes/visits), a group-join reward.

### First-5-minutes targets (design to these)
- First mog win in under 60 seconds, with a clear on-screen prompt and a big, funny payoff (the avatar visibly upgrades and the loser gets ragdoll knockback).
- First upgrade in under 2 minutes, first idle station in under 3, first rank-up in under 5.
- Keep the proven monetization surfaces (visible paid shortcuts, premium items in view, a starter pack), but no purchase prompt may open before the player's first win, and none from accidentally walking onto a pad during the tutorial.

## 5. Content rules (lawyer must check these)
- Roblox's audience is largely kids. Target the "Minimal" maturity label like the reference, with a parody/meme tone.
- Upgrades must be cartoonish (gym gear, skincare, outfits, hair, "aura"). NO real self-injury, bone-breaking, "bonesmashing", starving, steroids or surgery.
- No real people's names or likenesses (no influencers).
- Nothing copied from competitors. Our title must not be confusable with "+1 Mog Evolution".
- Check developer-product rules, any paid random items (odds disclosure), and purchase-prompt practices.
- Write findings in /docs/legal.md and flag anything that changes the design. State that this is not legal advice.

## 6. Team split for v1
- world-programmer + builder: hub, 2 worlds, idle-station rows, mog arenas, NPC opponent spots, a clear tutorial path.
- gameplay-programmer: click/stat system, tools, NPC mogging, Wins, idle stations, Rebirth/Ascend, Auto systems, rank ladder, tutorial quest chain.
- physics-programmer: mog battle animations, ragdoll knockback, avatar transformation effects, click "juice".
- systems-programmer: UI/HUD, DataStore saving (retries + session locking), leaderboards, developer products with correct ProcessReceipt handling (no lost purchases), codes, daily rewards, analytics events (session length, time to first win, rebirths, purchases).
- integration-programmer: writes architecture.md first, then merges branches and runs the full game.
- qa: balance (first win < 60 s, first rebirth ~10-15 min), mobile performance, exploit checks on remotes (no client-side currency), purchase-flow testing, a fun checklist for my playtest.
- marketer: name, description, keywords, icon + 3 thumbnail briefs (test the before/after idea with our own art), launch plan, and a first sponsored-ads test plan with a small budget.

## 7. Deliverables and gates
1. competitors.md + 3 twist options -> STOP for my pick.
2. gdd.md, legal.md, architecture.md and the tagged backlog -> STOP for my approval.
3. Only then start /sprint.
