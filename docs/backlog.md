# Backlog: "Aura Up!" (working title)
_Owned by project-manager. Re-scoped 2026-10-31 for D-034 (lean v1 built today, about 10 hours, World 1 only with 7 bosses). Sources: docs/gdd.md rev 2 (D-033), architecture v1, legal.md, decisions D-011..D-034._

**Plan (D-034):** Sprint 1 (code merged, D-032) -> Sprint 2 (M2 core, cloud, code only) -> Sprint 3 (duels + monetization, cloud, code only) -> Mac session (all art, Studio run, qa and owner playtest, publish). World 2 is "Update 1 (Saturday)"; polish and nice-to-haves are "Update 2 / later". The 16+ trial (GDD R-1) comes after publish.
**Global gates:** (1) Every monetization ticket can be built with placeholder prices and ids but cannot go live until the owner approves prices (gate 5) and creates the developer products in Creator Hub. (2) Only the owner playtests (gate 2) and publishes (gate 4). (3) Studio-dependent work (T-001, T-002, art, Studio run) waits for the Mac (D-022).
**Folder rule check:** Contracts + bootstraps + project config = integration; Gameplay + shared/Gameplay (incl. EconomyConfig) = gameplay; World + shared/World = world; Effects + shared/Physics = physics; UI + Data = systems; map and assets = builder; tests = qa; docs/legal.md = lawyer; docs/marketing = marketer. Within Sprint 2 and Sprint 3 each folder has exactly one writing role (checked per role list in each sprint heading). Cross-folder needs go through integration (T-048, T-069, T-072).
**Sizes:** S = under half a day, M = one day (D-034: today agents work in parallel, so S ~ 1 h and M ~ 2 h of wall time). Tags: world, gameplay, physics, systems, integration, art, qa, legal, marketing.
**Load warning:** gameplay-programmer is still the bottleneck (6 tickets per sprint). Overflow follows the cut-list order at the bottom.

---

## M1 Playable core loop (sprint 1)
Goal: spawn, tap, first win under 40 s, buy tools, beat 7 W1 bosses, save data. Owner playtest fits at end of S1.

### T-003 [integration] Update Contracts/Types.luau ProductKey to the rev 1 list of 23 products and sweep architecture   (M)  sprint: 1  owner: integration-programmer
Depends on: none
Acceptance criteria:
- [ ] `T.ProductKey` has exactly the 23 GDD section 8 products: Ladder x2/x4/x8/x16/x32 (5), Hype Snack, Speed Sneakers, Auto Clicker, Ring Light Retriever, Neon Pup, Golden Glow Fit, Neon Icon Fit, VIP, Starter Pack, Star Egg 1/3, Galaxy Egg 1/3, Tip 5/25/100/500/1000 (count checked: 23). Removed: Coin Pouch/Bag/Vault, paid Coin Snack, pod unlocks, Skip Rebirth, Skip to World 2, Auto-Mog Early
- [ ] Matching `GrantKind` list trimmed; `PlayerAttr.AutoMogEarlyOwned` and `skipRebirthsUsed` / `autoMogEarly` profile fields removed; `RebirthService.tryRebirth` loses its `skip` argument; `RequestPurchase` rules for Skip Rebirth / Skip World 2 removed
- [ ] Remove D-017's default coin-egg gate from architecture 4d under option A (D-019 #1), pending the owner's choice; every "34 products" reference becomes 23; section 4d states the B-1 policy default and what changes under A or B; Starter Pack described without coins (30 min Hype Snack + Sparkle Pup + Rookie Shades)
- [ ] `selene` and `stylua` clean; gameplay/systems tickets notified through the Contract requests table
Status: done (merged to main, D-032)

### T-004 [integration] Contracts/RateLimit.luau and NumberFormat.luau   (S)  sprint: 1  owner: integration-programmer
Depends on: none
Acceptance criteria:
- [ ] RateLimit token bucket reads `Remotes.Definitions[name].rate/burst`, drops silently, and clears on PlayerRemoving
- [ ] NumberFormat handles K/M/B/T/Qa and values up to 1e18 without errors; unit-checkable pure functions
Status: done (merged to main, D-032)

### T-005 [legal] Re-review GDD rev 1 changed sections and residual risk R-5   (S)  sprint: 1  owner: lawyer
Depends on: none
Note: done in D-019 (B-1 resolved under option A, R-5 ruled compliant). Open follow-ups moved to T-053 (ladder fallback change) and T-084 (read the DevForum post and live policy page).
Acceptance criteria:
- [ ] docs/legal.md updated: rev 1 sections (1, 4.1, 4.3, 4.5-4.7, 5, 8, 10-14) checked; B-1 option A confirmed or rejected
- [ ] Ruling on R-5 (paid MP ladder reaches richer bosses sooner) recorded; if rejected, team-lead is told to switch to option B
- [ ] Any new BLOCKER is named with a fix
Status: done

### T-006 [gameplay] EconomyConfig core: tools, pods, bosses, ranks, rebirth, caps, formulas   (M)  sprint: 1  owner: gameplay-programmer
Depends on: none
Acceptance criteria:
- [ ] All GDD 4.2-4.5 and 7 tables as data (12 tools, 7 pods, 13 bosses, 12 ranks, rebirth cost, caps `TAP_CAP_PER_SEC`, `M_CLAMP`, `INTERACT_RANGE`) with the architecture 1c function surface
- [ ] Pure functions `rebirthCost`, `rebirthMult`, `coinRebirthMult`, `paidTierMult`, `petSlots`, `duelScore`; no number hard-coded elsewhere
- [ ] `--!strict`, no Roblox services; values match the GDD tables exactly (spot-checked by qa in T-024)
Status: done (merged to main, D-032)

### T-007 [gameplay] ActivityService and MultiplierService   (M)  sprint: 1  owner: gameplay-programmer
Depends on: T-006, T-012
Acceptance criteria:
- [ ] `tryBegin/finish/get` with an exclusive Activity attribute; cleans up on PlayerRemoving
- [ ] M pipeline from architecture 4a computed on events only, clamped 1..`M_CLAMP`, NaN gives 1; `Multiplier` and `CoinMultiplier` attributes written by this service only
- [ ] Hype Snack and Coin Snack timers tick only while online and cap at 2 h
Status: done (merged to main, D-032)

### T-008 [gameplay] TapService   (M)  sprint: 1  owner: gameplay-programmer
Depends on: T-004, T-006, T-007, T-012
Acceptance criteria:
- [ ] `TapBatch` handler: integer 1..30, token bucket at 12/s minus AutoTapRate, silent drop on spam, DataLoaded check first
- [ ] `addMp` is the only MP writer; updates mp and lifetimeMp, calls `RankService.onLifetimeMp`; `MpPerTap` attribute written
- [ ] `setTapSink` supported for duels; client cannot send an amount (count only)
Status: done (merged to main, D-032)

### T-009 [gameplay] BossService (fight, coins, FirstWin)   (M)  sprint: 1  owner: gameplay-programmer
Depends on: T-006, T-007, T-008, T-012, T-016
Acceptance criteria:
- [ ] `RequestBossFight` validates id, world, distance, `Mp >= need`, `Activity`; 3 s fight + 1 s cycle; re-checks presence before awarding
- [ ] Coins = BossCoins x `coinRebirthMult` x Coin Snack; no pet or paid term; `FirstWin`, `BestCoinsPerSec` written; `BossWon` signal; `PlayEffect BossWin` fired
- [ ] Works with 12 players fighting at once without server lag
Status: done (merged to main, D-032)

### T-010 [gameplay] ShopService (BuyTool, BuyPod)   (S)  sprint: 1  owner: gameplay-programmer
Depends on: T-006, T-012, T-016
Acceptance criteria:
- [ ] `BuyTool` only `ToolIndex + 1`, world unlocked, `trySpendCoins`; `BuyPod` 1..7 not owned, coins only (no Robux path)
- [ ] `ToolIndex` and `PodsMask` attributes written; `getToolPower` used by TapService; signals fired
Status: done (merged to main, D-032)

### T-011 [gameplay] RankService   (S)  sprint: 1  owner: gameplay-programmer
Depends on: T-006, T-012
Acceptance criteria:
- [ ] Rank computed from lifetime MP against the 12-rank table; `RankUp` signal; `Rank`, `LookId` attributes
- [ ] Calls `CharacterService.setLook` and fires `PlayEffect RankUp` plus a server banner (rate-limited)
Status: done (merged to main, D-032)

### T-012 [systems] DataService (ProfileStore, Data API, attributes, leaderstats)   (M)  sprint: 1  owner: systems-programmer
Depends on: T-003 (T-001 waived under D-022; ProfileStore calls carry TODO(verify-api))
Acceptance criteria:
- [ ] Profile schema v1 from architecture 3a (without Skip Rebirth fields); `Reconcile`; load failure kicks with a friendly message
- [ ] API `getData/addCoins/trySpendCoins/update/waitForData/getSetting`; data attributes flushed at most 5 Hz; leaderstats Rank and Rebirths
- [ ] Save on leave and shutdown; test that a rejoin keeps coins and MP; session lock verified with two Studio clients
Status: done (merged to main, D-032)

### T-013 [systems] ComplianceService (PolicyService gate)   (S)  sprint: 1  owner: systems-programmer
Depends on: T-012
Acceptance criteria:
- [ ] `GetPolicyInfoForPlayerAsync` called on the server inside `pcall`, 3 tries with 2/4/8 s backoff, cached per player
- [ ] Any failure gives `PaidRandomAllowed = false` (fail closed); attribute is read-only UI info; `paidRandomAllowed()` API
Status: done (merged to main, D-032)

### T-014 [systems] HUD, TapController and first-minute guidance   (M)  sprint: 1  owner: systems-programmer
Depends on: T-004, T-008, T-009, T-012
Acceptance criteria:
- [ ] MP, coins, rank, meter "100 MP to beat Sleepy Sid", floor arrow and "TAP to power up!" per GDD 9; collapsed leaderboard; shop buttons hidden until `FirstWin`
- [ ] Tap capture for touch and mouse not over GUI, local cap 12/s, batch every 0.5 s, 44 px minimum touch targets, safe-area aware
- [ ] Numbers use NumberFormat; works on a phone-size emulator
Status: done (merged to main, D-032)

### T-015 [systems] MOG button, Tool shop UI and notification toasts   (M)  sprint: 1  owner: systems-programmer
Depends on: T-009, T-010, T-012, T-014
Acceptance criteria:
- [ ] Grey MOG button "Need 600 MP (you: 412)" turning active at the threshold; fires `RequestBossFight`
- [ ] Tool Stand UI (ProximityPrompt opens it, no purchase prompt) fires `BuyTool`; next tool only
- [ ] `Notify` toasts (max 3) and server banners
Status: done (merged to main, D-032)

### T-016 [world] MapLayout and ZoneService core   (M)  sprint: 1  owner: world-programmer
Depends on: T-003
Acceptance criteria:
- [ ] MapLayout is the only code that knows tag and attribute names (architecture 1f); nil-safe for streaming
- [ ] ZoneService: `getWorld`, `isNearBoss`, stage and stand lookup; `WorldId` attribute; spawn placement
- [ ] Documented tag contract handed to builder in the same file header
Status: done (merged to main, D-032)

### T-017 [world] CharacterService basic (walk speed and movement locks)   (S)  sprint: 1  owner: world-programmer
Depends on: T-016
Acceptance criteria:
- [ ] Single writer of WalkSpeed and JumpPower; reason-keyed `setMovementLocked`; `setSpeedMultiplier`
- [ ] Survives respawn
Status: done (merged to main, D-032)

### T-021 [physics] EffectsConfig and tap sparkle / coin burst effects (pooled)   (M)  sprint: 1  owner: physics-programmer
Depends on: T-003
Acceptance criteria:
- [ ] `EffectsConfig` (pool sizes, particle budgets, timings); `EffectsController` dispatches `PlayEffect`
- [ ] Tap sparkles pooled (20), at most 300 particles alive, at most 2 ms per frame on low-end mobile
Status: done (merged to main, D-032)

### T-024 [qa] Test project, EconomyConfig validation and timing sim script   (M)  sprint: 1  owner: qa
Depends on: T-006
Acceptance criteria:
- [ ] `test.project.json` and tests run; `EconomyConfig.validate()` and a tables-match-GDD check run in tests
- [ ] Sim script reproduces GDD 4.7 (first win about 0:38, first rebirth 12-14 min) at 5 and 3 taps/s; report in docs/qa/
Status: done (merged to main, D-032)

### T-025 [qa] M1 exploit tests (tap flood, remote spam, bad arguments)   (S)  sprint: 1  owner: qa
Depends on: T-008, T-009, T-010
Acceptance criteria:
- [ ] Fuzz tests on TapBatch, RequestBossFight, BuyTool (NaN, inf, negative, huge, wrong types, too-far player); none credit anything
- [ ] Bugs filed in docs/qa/ with repro steps
Status: done (merged to main, D-032)

### T-026 [integration] Bootstrap wiring and sprint 1 merge   (S)  sprint: 1  owner: integration-programmer
Depends on: T-003, T-004, T-007, T-008, T-009, T-012, T-014, T-016, T-021
Acceptance criteria:
- [ ] Main.server and Main.client load all modules in the architecture order; `Init` never yields
- [ ] Branches merged to `main` one ticket per commit; `main` plays in Studio from spawn to first boss win and survives rejoin
Status: done in code (merged, D-032); Studio play-through moves to T-094 (Mac)

---

## Sprint 2 (M2 core, code only, cloud, about 3.5 h)
**Status: merged to main at 159a05d (build 2, docs/qa/build-2.md). Code and static checks only; Studio checks are pending on the Mac (T-094): Play-mode specs that SKIP (PetEquip, PetRoll, Rebirth, Idle), Studio specs, persistence with a real DataStore, hatch and rank-up visuals, phone-size UI.**
Goal: pets and coin eggs, idle/auto, rebirth, telemetry, rank looks and cinematics in code, D-033 config. Per role: gameplay T-088, T-027..T-031; systems T-033..T-036; world T-038; physics T-043..T-045; qa T-046, T-047; integration T-048 (merge last).

**Bug intake (docs/qa/bugs.md, copied 2026-10-31 after build 2):** sprint-1 intake (QA-F1..F5) is closed. The 11 items still under "Open" in bugs.md are listed below. A static read of `main` at 159a05d shows the fix in code for every one; qa has not yet moved them to Closed, so they stay open until qa confirms (a Studio re-run for the client ones). No S1 is open.
| Bug | Role | Sev | Code state on main (static read) | Verify |
|---|---|---|---|---|
| QA-1 Tool Stand prompt never opens shop | systems | S2 | `GameData.isShopPrompt` now walks ancestors with `getShopKindOf` | Studio (T-094) |
| QA-2 MOG button hidden when stage is a Model | systems | S2 | `GameData.positionOf(bossStage(..))` used in HudController | Studio (T-094) |
| QA-3 AutoTap check duplicate rule | systems | S3 | reads `AutoTapUnlocked` attribute | qa static |
| QA-4 `auto` truthy skips range | gameplay | S3 | `auto ~= true` | qa static |
| QA-5 Pets must refresh M | gameplay | S2 | `refresh` called in PetService (3 call sites) | qa check_authority + PetEquip spec (Play mode) |
| QA-8 BossWon reports balance | gameplay | S2 | `added` is now `coins` or 0 | qa static |
| QA-9 Silent boss-stage fallback | world | S3 | `warnMissingOnce` | qa static |
| QA-10 Rank 2 at 2,500 | gameplay | S3 | 1800 (T-088) | qa EconomyConfig spec |
| QA-11 schemaVersion below 1 throws | systems | S3 | migrate guards `version < 1` | qa Persistence spec |
| QA-F7 No pure roll helper | gameplay | S3 | `Gameplay/Util/PetRoll.luau` exists | qa PetRoll spec (SKIPs until run in Studio) |
| QA-F8 No setEquipped/deletePets | gameplay | S3 | both exist in PetService | qa PetEquip spec (Play mode) |
New sprint-3 gameplay items from the owner hand-off (not in bugs.md, see T-095): `equipped` local-name false positive in `check_authority`, and `UID_MAX` vs `PET_UID_MAX_LEN`. Any bug qa files later is added as an acceptance line on the owner's sprint 3 ticket.

### T-088 [gameplay] Apply D-033 balance change: RANKS[2].lifetimeMp = 1800 (QA-F1)   (S)  sprint: 2  owner: gameplay-programmer
Depends on: T-006
Acceptance criteria:
- [ ] `EconomyConfig.RANKS[2].lifetimeMp` is 1800 (was 2500); no other value changes
- [ ] `EconomyConfig.validate()` still passes; rank thresholds stay strictly increasing
- [ ] No gameplay bug from docs/qa/bugs.md is open besides QA-F1 (QA-F4 done in D-032, QA-F5 fixed); placeholder: more bugs may come from qa review, fold them in here
Status: done in code (merged to main 159a05d, build 2, D-051)

### T-027 [gameplay] EconomyConfig eggs, pets and odds (W1 only: Basic, Shiny, Star, Galaxy eggs; fixed pets)   (M)  sprint: 2  owner: gameplay-programmer
Depends on: T-006
Acceptance criteria:
- [ ] GDD section 5 tables as integer weights summing to 10,000 per egg; `restrictedGrant` for Star (Starlight Corgi) and Galaxy (Nebula Fox); pity 10 flag only on Robux eggs
- [ ] Fixed pets and `COIN_EGGS_POLICY_GATED` flag present (default false per option A, D-021; T-029 removes the gate code)
- [ ] `validate()` asserts weight sums
- [ ] Lean v1 (D-034): Neon and Runway egg data and W2 pets move to T-090 (Update 1)
Status: done in code (merged to main 159a05d, build 2, D-051)

### T-028 [gameplay] PetService: coin egg hatch, roll, inventory, equip, delete   (M)  sprint: 2  owner: gameplay-programmer
Depends on: T-027, T-007, T-012, T-016
Acceptance criteria:
- [ ] `HatchEgg`, `EquipPet`, `DeletePets` validated per architecture section 2; one server `Random`; cost, roll and insert in one `DataService.update`
- [ ] Slots 3 (+1 R3, +1 R8, +1 VIP); cap 60; hatch x3 at R2; auto-delete Commons; `HatchResult` to hatcher only
- [ ] While `COIN_EGGS_POLICY_GATED` is true and `PaidRandomAllowed` is false, coin eggs are refused
- [ ] Lean v1 (D-034): W1 eggs only (Basic, Shiny coin eggs; Star and Galaxy rolls are built in T-073)
Status: done in code (merged to main 159a05d, build 2, D-051)

### T-029 [gameplay] Coin-egg policy gating per owner B-1 choice   (S)  sprint: 2  owner: gameplay-programmer
Depends on: T-028
Acceptance criteria:
- [ ] Option A (approved, D-021): `COIN_EGGS_POLICY_GATED = false` by default, gate code removed, coin eggs open to all players; qa test confirms restricted players can hatch coin eggs
- [x] Option B not chosen; "Conditional work" tickets stay unused
- [x] Decision recorded in decisions.md as Approved by owner (D-021)
Status: done in code (merged, D-051)

### T-030 [gameplay] IdleService: pod MP/s, Auto-Tap and Auto-Mog   (M)  sprint: 2  owner: gameplay-programmer
Depends on: T-007, T-008, T-009, T-016
Acceptance criteria:
- [ ] One 1 Hz loop for all players; only the pod the player stands in counts; Auto-Tap 3/s from Rank 3 (Auto Clicker 6/s hook for later); total capped at 12/s
- [ ] Auto-Mog from Rebirth 1 refights the best beatable boss every 5 s, including while in a pod; paused in duels; no paid early unlock
Status: done in code (merged to main 159a05d, build 2, D-051)

### T-031 [gameplay] RebirthService (no skip; World 2 unlock moved to T-091)   (M)  sprint: 2  owner: gameplay-programmer
Depends on: T-007, T-010, T-012
Acceptance criteria:
- [ ] `RequestRebirth` computes cost on the server; atomic reset of MP, coins and tools; keeps pods, pets, rank, paid items, codes
- [ ] +0.5 MP and +10% coins per rebirth; no skip argument anywhere; no World 2 unlock in v1 (T-091), the `World2Unlocked` attribute stays false
Status: done in code (merged to main 159a05d, build 2, D-051)

### T-038 [world] Pod presence, egg stands, rank looks and fits (W1; portal sign only)   (M)  sprint: 2  owner: world-programmer
Depends on: T-016, T-017 (art T-039/T-040 not required: code is nil-safe, see D-030 pattern)
Acceptance criteria:
- [ ] Server zone check for pods; `getPod` and `PodChanged`; Portal `Touched` only shows "World 2 coming Saturday" and never teleports (teleport = T-092); `isNearEggStand`
- [ ] `CharacterService.setLook` layers cartoon accessories (at most 6), no body edits; respects the ShowOwnLook setting
- [ ] Placeholder: qa is still reviewing sprint 1; fix any bug filed in docs/qa/bugs.md for this folder before closing (project-manager folds new bugs in at the start of each sprint)
Status: done in code (merged to main 159a05d, build 2, D-051)

### T-033 [systems] TelemetryService (funnel and economy events)   (S)  sprint: 2  owner: systems-programmer
Depends on: T-012
Acceptance criteria:
- [ ] Funnel steps deduped via `profile.milestones`; economy, custom and progression events; keyed by UserId only, no free text; never per tap; at most 1 event per 5 s average
- [ ] Gameplay calls verified on first win, first upgrade, pod, rank-up, rebirth
- [ ] T-002 is deferred to the Mac: use custom events with `TODO(verify-api)` on any AnalyticsService call
Status: done in code (merged to main 159a05d, build 2, D-051)

### T-034 [systems] Pod, Rebirth and Settings UI   (M)  sprint: 2  owner: systems-programmer
Depends on: T-010, T-030, T-031
Acceptance criteria:
- [ ] Pod shop (coins only), "REBIRTH READY" pulse, rebirth confirm, Settings toggles via `SetSetting` (duels, own look, auto-delete, auto-tap, auto-mog, donor board)
- [ ] Auto-Tap and Auto-Mog toggles locked until unlocked
- [ ] Rebirth screen shows a "World 2 coming Saturday" notice instead of a World 2 unlock (D-034)
- [ ] Placeholder: qa is still reviewing sprint 1; fix any bug filed in docs/qa/bugs.md for this folder before closing (project-manager folds new bugs in at the start of each sprint)
Status: done in code (merged to main 159a05d, build 2, D-051)

### T-035 [systems] EggController: coin egg UI with exact odds   (M)  sprint: 2  owner: systems-programmer
Depends on: T-028
Acceptance criteria:
- [ ] Egg stand ProximityPrompt opens UI listing exact percentages, bonuses and "you own" ticks before every purchase; hatch x1 / x3
- [ ] Odds are rendered from the same EconomyConfig table the server rolls
- [ ] Hatch result screen with skip
- [ ] Lean v1 (D-034): W1 eggs only (Basic, Shiny)
Status: done in code (merged to main 159a05d, build 2, D-051)

### T-036 [systems] PetsController: inventory, equip best, multi-delete   (M)  sprint: 2  owner: systems-programmer
Depends on: T-028
Acceptance criteria:
- [ ] 60-pet grid, equip and unequip, equip best, multi-delete with confirm; slot count shown
- [ ] Works on a phone-size screen
Status: done in code (merged to main 159a05d, build 2, D-051)

### T-043 [physics] Rank-up cinematic (spotlight, orbit, confetti)   (M)  sprint: 2  owner: physics-programmer
Depends on: T-011, T-021
Acceptance criteria:
- [ ] 3 s moment from `PlayEffect RankUp`; nearby players see the look pop; camera restored afterward; skippable
- [ ] Code-only: confetti and spotlight from `PlayEffect RankUp`; no model needed
Status: done in code (merged to main 159a05d, build 2, D-051)

### T-044 [physics] PetFollowController   (M)  sprint: 2  owner: physics-programmer
Depends on: T-028 (T-042 not required)
Acceptance criteria:
- [ ] Renders equipped pets of players within 120 studs; at most 36 pet models alive; one Heartbeat loop with `BulkMoveTo`; no collisions
- [ ] Falls back to a plain sphere part when the pet model is missing (models come in T-042 on the Mac)
Status: done in code (merged to main 159a05d, build 2, D-051)

### T-045 [physics] Hatch animation (about 2 s, skippable)   (S)  sprint: 2  owner: physics-programmer
Depends on: T-035, T-021
Acceptance criteria:
- [ ] Plays from `HatchResult`; skip works; x3 hatch shows 3 reveals
Status: done in code (merged to main 159a05d, build 2, D-051)

### T-046 [qa] Persistence, rebirth and pet-roll tests   (M)  sprint: 2  owner: qa
Depends on: T-012, T-028, T-031
Acceptance criteria:
- [ ] Rejoin keeps coins, MP, tools, pods, pets, rank; rebirth resets exactly the right fields; no dupes on server hop
- [ ] 100,000 simulated rolls per egg land within tolerance of the listed odds
- [ ] Placeholder: more bugs may come from the ongoing sprint 1 review; new items go to docs/qa/bugs.md and are folded into owners' tickets
Status: done in code (specs written; Play-mode specs SKIP until the Studio run, pending on the Mac)

### T-047 [qa] Economy sim vs GDD 4.7 and tuning report   (S)  sprint: 2  owner: qa
Depends on: T-024, T-030, T-031, T-088
Acceptance criteria:
- [ ] Sim confirms R1 about 12-14 min, R3 about 40 min, R10 about 4 h at 5 taps/s; any retune is only a value change in EconomyConfig (request to gameplay)
- [ ] Rerun the sim after D-033 (Rank 2 at 1,800 lifetime MP); update `GDD_TIMES`, `TARGETS` and the GddTables fixture (D-033, GDD 4.8); first rebirth band 10:30-12:00 at 5 taps/s, 12:30-15:00 at 3 taps/s
Status: done in code (sim passes with D-052 tolerance; QA-F6 closed)

### T-048 [integration] Sprint 2 merge and contract requests   (S)  sprint: 2  owner: integration-programmer
Depends on: T-088, T-027..T-036, T-038, T-043..T-045
Acceptance criteria:
- [ ] Open Contract requests resolved; merge to `main`; spawn to first rebirth to egg hatch plays end to end
Status: done in code (merged, D-051). "Spawn to first rebirth to egg hatch plays end to end" is pending on the Mac (T-094)

---

## Sprint 3 (duels + monetization, code only, cloud, about 3.5 h)
**Status: in progress. Prices approved (D-038), so the monetization tickets are unblocked for go-live except the owner steps (create the developer products in Creator Hub, enter ids).** Per role (T-095 added to gameplay; T-071 legal unblocked).
Goal: daily reward, quests, PvP duels with ragdoll code, MonetizationService, shop, Robux eggs. Monetization tickets are built with placeholder prices and ids; they cannot go live until the owner approves prices (gate 5) and creates the developer products. Per role: gameplay T-095, T-032, T-049, T-050, T-052, T-053, T-073; systems T-054..T-058; world T-059; physics T-066; qa T-068, T-081; integration T-069, T-072 (merge last); legal T-071; marketing T-085.

### T-095 [gameplay] PetService small fixes: rename `equipped` local, UID_MAX = 1e12-1   (S)  sprint: 3  owner: gameplay-programmer
Depends on: T-028
Acceptance criteria:
- [ ] In `PetService.inventoryString` (src/server/Gameplay/PetService.luau, about line 159) rename the local table `equipped` (for example `isEquipped`) so `tests/static/check_authority.py` no longer flags it as a false positive; behaviour unchanged, PetInventory string identical
- [ ] `UID_MAX` (line 35) becomes `1e12 - 1` so `tostring(uid)` never exceeds `PET_UID_MAX_LEN` (12); `Guard.clampFinite(nextUid, 1, UID_MAX, 1)` still used
- [ ] `check_authority.py` run clean for PetService; selene and stylua clean
Status: in-progress (sprint 3)

### T-032 [gameplay] QuestService tutorial chain   (M)  sprint: 3  owner: gameplay-programmer
Depends on: T-009, T-010, T-011, T-028
Acceptance criteria:
- [ ] Chain per GDD 9: win 5 more, Hair Gel, beat Benny, Ring Light Pod, Mask, rank-up, first egg; `QuestStep`, `TutorialDone`
- [ ] `TutorialCompleted` unlocks duels and the Starter Pack pop-up timing
- [ ] Runs first in sprint 3: duels need `TutorialCompleted`
Status: in-progress (sprint 3)

### T-049 [gameplay] DuelService core (state machine, tap sink, scoring)   (M)  sprint: 3  owner: gameplay-programmer
Depends on: T-008, T-032 (ring API T-059 is built in the same sprint)
Acceptance criteria:
- [ ] Pending 10 s, Countdown 3 s, Active 8 s, Result, Rematch window; `DuelState` timestamps; tap sink clamped to 10/s and 80 total
- [ ] Score = taps x (1 + 0.03 x min(own rank, opponent rank + 2)); pets, paid tier, VIP, boosts and auto-tap never read; Auto-Tap and Auto-Mog paused
- [ ] Ring/pit positions come from `ZoneService` (T-059); no ragdoll logic here
Status: in-progress (sprint 3)

### T-050 [gameplay] Duel rewards, anti-grief, rematch, forfeit   (M)  sprint: 3  owner: gameplay-programmer
Depends on: T-049
Acceptance criteria:
- [ ] Reward 120 x best coins/s only under 5 per hour and 2 per opponent per 15 min; losers lose nothing
- [ ] Cooldown 15 s, 1 pending outgoing, 3-decline mute, session block list, forfeit on leave, ring released
Status: in-progress (sprint 3)

### T-052 [gameplay] RewardService: 7-day daily calendar   (S)  sprint: 3  owner: gameplay-programmer
Depends on: T-007, T-028, T-012
Acceptance criteria:
- [ ] Server UTC day logic; missing a day restarts at D1; D1-D7 per GDD 10 (D5 Coin Snack is free; D7 cosmetic kept)
- [ ] No paid item changes a daily coin or egg reward (VIP adds only 10 min Hype Snack)
Status: in-progress (sprint 3)

### T-053 [gameplay] Robux grants: ladder (next-tier + fallback), VIP, Hype Snack, Auto Clicker, Starter Pack   (M)  sprint: 3  owner: gameplay-programmer
Depends on: T-003, T-007, T-056
Acceptance criteria:
- [ ] NOTE (D-021): the D-019 #3 ladder-receipt fix waits for the owner's price review; build with GDD placeholder prices, nothing goes live until prices are approved (gate 5)
- [ ] Registered with `registerGrant`; a receipt for the next tier grants it; any receipt that is NOT for the next tier (owned, lower or higher) grants Hype Snack time at 10 min per 2 R$ instead, cap bypassed and logged (D-019 #3; this replaces the GDD rev 1 "next unowned tier" fallback, and the GDD needs a rev 2 edit by the scenarist)
- [ ] Hype Snack purchase blocked once the 2 h cap would be exceeded; Starter Pack once, with no coins, pod or egg
- [ ] No grant touches coins, coin-shop items, rebirths or egg hatches (T-081 checks this)
- [ ] Lean v1 (D-034): Speed Sneakers moves to Update 2 (already first on the cut list)
Status: in-progress (sprint 3); prices approved (D-038). Go-live waits only for the owner to create the developer products

### T-073 [gameplay] Robux-egg grants: server roll, saved pity, true odds, restricted fixed-pet fallback, fixed pet grants   (M)  sprint: 3  owner: gameplay-programmer
Depends on: T-028, T-056, T-027
Acceptance criteria:
- [ ] Star and Galaxy grants (1 and 3 packs); 10th hatch without Legendary+ forces Legendary 90 / Mythic 10; counter saved per egg; 3-pack counts in order
- [ ] A restricted player's receipt grants the stated fixed pet (Starlight Corgi / Nebula Fox, 3 copies for a 3-pack) with a log, never a roll and never nothing; inventory may exceed 60 by up to 6
- [ ] Ring Light Retriever grant only (Neon Pup moves to Update 2); no egg in any bundle
Status: in-progress (sprint 3); prices approved (D-038). Go-live waits only for the owner to create the developer products

### T-059 [world] ZoneService rings (World 1) and duel movement lock   (M)  sprint: 3  owner: world-programmer
Depends on: T-038 (map art T-061 not required: code is nil-safe)
Acceptance criteria:
- [ ] `reserveRing/releaseRing/teleportToRing/getRingKnockback` (`teleportToWorld` moves to T-092); both rings can run at once; rings released on leave
- [ ] CharacterService movement lock during duels
Status: in-progress (sprint 3)

### T-056 [systems] MonetizationService core (ProcessReceipt, dedupe, RequestPurchase gate, grant registry)   (M)  sprint: 3  owner: systems-programmer
Depends on: T-003, T-012, T-013, T-069
Acceptance criteria:
- [ ] The only `ProcessReceipt`; grant and receipt id in one `DataService.update`; granted only after the save that holds the id; unknown id gives NotYetProcessed
- [ ] `RequestPurchase` gates: FirstWin (prompt only), next ladder tier only, permanent items not owned, Robux eggs need `PaidRandomAllowed`; server-side prompt; every valid receipt is delivered even before FirstWin
- [ ] Entitlement attributes and `EntitlementsChanged`
Status: in-progress (sprint 3); prices approved (D-038). Go-live waits only for the owner to create the developer products

### T-057 [systems] Robux shop UI (ladder, boosts, VIP, fixed pets, cosmetics, boost cap HUD)   (M)  sprint: 3  owner: systems-programmer
Depends on: T-056, T-053
Acceptance criteria:
- [ ] Only the next ladder tier is shown, with "Does not stack: the highest tier you own applies"; named "x2 Mog Points", never earnings or coins; "Permanent" labels
- [ ] HUD shows boost time left and the 2 h cap; boost time stated as in-game only; "Exclusive", no "Limited"
- [ ] Buttons hidden until FirstWin; no wall of buy buttons; Starter Pack pop-up once after the first rank-up
Status: in-progress (sprint 3); prices approved (D-038). Go-live waits only for the owner to create the developer products

### T-058 [systems] Robux egg UI (odds, pity text, true odds at 9/10, restricted stand text)   (M)  sprint: 3  owner: systems-programmer
Depends on: T-056, T-035
Acceptance criteria:
- [ ] Odds on the egg UI and in the confirmation step; pity rule written out; counter "Pity: 7/10" saved per egg; at 9/10 the real next-hatch odds replace the table; 3-pack lists odds per hatch; "Odds Info" button label
- [ ] Restricted players see "Robux eggs aren't available on your account" and the stated fixed pet text, with no buy button
Status: in-progress (sprint 3); prices approved (D-038). Go-live waits only for the owner to create the developer products

### T-054 [systems] DuelController UI   (M)  sprint: 3  owner: systems-programmer
Depends on: T-049, T-050
Acceptance criteria:
- [ ] Challenge button on players, accept and decline with a 10 s timer, countdown, tap-off HUD, result, rematch, block; text "Out-glowed! Rematch?" only
Status: in-progress (sprint 3)

### T-055 [systems] RewardsController (daily calendar UI)   (S)  sprint: 3  owner: systems-programmer
Depends on: T-052
Acceptance criteria:
- [ ] 7-day calendar with claim button and next-claim time; no codes box in v1 (T-074 is Update 2)
Status: in-progress (sprint 3)

### T-066 [physics] RagdollController (duel knockback) and ring effects, code-only   (M)  sprint: 3  owner: physics-programmer
Depends on: T-049 (map art T-061 not required)
Acceptance criteria:
- [ ] Local player's own 2.5 s cartoon ragdoll into the foam pit only when the server names that user; always recovers; no ragdoll outside rings
- [ ] Draw bounce effect; winner pose banner
- [ ] Code-only: ring and pit positions read from MapLayout; Studio tuning with the real ring is T-089 (Mac)
Status: in-progress (sprint 3)

### T-068 [qa] Duel and reward exploit tests   (M)  sprint: 3  owner: qa
Depends on: T-050, T-052
Acceptance criteria:
- [ ] Tap-flood in duels, win-trading with two accounts, forfeit abuse, daily claim replay, challenge spam; none give unearned rewards
Status: in-progress (sprint 3)

### T-081 [qa] Coin-firewall test and purchase-flow tests (incl. restricted receipts)   (M)  sprint: 3  owner: qa
Depends on: T-053, T-073, T-056
Acceptance criteria:
- [ ] Test walks every product's grant function and fails if any touches coins, coin-shop items, rebirth count or egg hatches (GDD 8g)
- [ ] Receipt tests: duplicate receipt, receipt before FirstWin, non-next-tier receipt gives Hype Snack only (no tier climb), boost cap, restricted-player egg receipt; all grant exactly once
Status: in-progress (sprint 3); prices approved (D-038). Go-live waits only for the owner to create the developer products

### T-069 [integration] ProductCatalog.luau (23 keys, product ids, grant kinds, price labels)   (S)  sprint: 3  owner: integration-programmer
Depends on: T-003
Acceptance criteria:
- [ ] Every key maps to an id the owner created in Creator Hub (ids entered by the owner; none in repo secrets), grant kind and price label matching the approved prices
- [ ] Count is 23 and the file is the only place with ids
- [ ] D-038 approved 15 of the 23 products (ladder x2/x4/x8/x16/x32 = 4/8/19/39/79, Hype Snack 2, Starter Pack 9, Ring Light Retriever 29, Auto Clicker 39, VIP 99, Golden Glow Fit 249, Star Egg 25 / 3-pack 69, Galaxy Egg 49 / 3-pack 129). Speed Sneakers, Neon Pup, Neon Icon Fit and 5 tips are not approved: flag them `offered = false` in the catalog and never prompt them
Status: in-progress (sprint 3); prices approved (D-038). Build with placeholder id 0 and a validator that refuses purchases on id 0; the owner creates the 15 approved developer products in Creator Hub and enters ids

### T-072 [integration] Sprint 3 merge   (S)  sprint: 3  owner: integration-programmer
Depends on: T-049..T-069 (all sprint 3 tickets)
Acceptance criteria:
- [ ] Merge to `main`; two real players can duel; the portal shows "World 2 coming Saturday"; the daily reward claims
Status: in-progress (sprint 3)

### T-071 [legal] Review product listings, descriptions and maturity questionnaire answers   (S)  sprint: 3  owner: lawyer
Depends on: T-057, T-058
Acceptance criteria:
- [ ] Listing text checked against GDD 8 rules (e), (h), (i); no claim that money can't affect PvP (paid MP speeds up rank, up to +6% duel edge, D-019 #4); the odds text; the questionnaire answer "paid random items: yes"; result in docs/legal.md
Status: in-progress (sprint 3); unblocked by D-038

### T-085 [marketing] Launch kit (lean)   (M)  sprint: 3  owner: marketer
Depends on: none (T-084 runs in the Mac session)
Acceptance criteria:
- [ ] docs/marketing/ has: description (the word "mog" only here and in tags; no "looksmax"), tags, update-note template for numbered weekly updates, code-post wording (milestone wording rule), thumbnail and icon brief, 3 short video or social clips outline, Saturday event announcement templates
- [ ] No competitor names or "Minimal" claim; no ad spend (gate 3)
- [ ] Lean v1 (D-034): update-note template, clip outline and Saturday event templates move to Update 2
Status: in-progress (sprint 3)

---

gal.md
Status: in-progress (sprint 3); unblocked by D-038

### T-085 [marketing] Launch kit (lean)   (M)  sprint: 3  owner: marketer
Depends on: none (T-084 runs in the Mac session)
Acceptance criteria:
- [ ] docs/marketing/ has: description (the word "mog" only here and in tags; no "looksmax"), tags, update-note template for numbered weekly updates, code-post wording (milestone wording rule), thumbnail and icon brief, 3 short video or social clips outline, Saturday event announcement templates
- [ ] No competitor names or "Minimal" claim; no ad spend (gate 3)
- [ ] Lean v1 (D-034): update-note template, clip outline and Saturday event templates move to Update 2
Status: in-progress (sprint 3)

---

## Mac session (owner at the Mac with Studio, about 3 h)
All [art] tickets, ragdoll/camera work that needs models, the Studio full-game run, the qa playtest, the owner playtest (gate 2) and the owner publish (gate 4). Order: T-001/T-002 and /toolcheck, T-018..T-020, T-039..T-042, T-061, T-065, T-094, T-022/T-023/T-089, T-082/T-083, T-084, owner playtest, T-087 fixes, T-086, T-080 icon, owner publishes.

### T-001 [integration] Verify ProfileStore API and add via Wally   (S)  sprint: Mac  owner: integration-programmer
Depends on: owner `/toolcheck` pass
Acceptance criteria:
- [ ] `wally search profilestore` confirms scope, name and version; `wally.toml` updated; `wally install` works
- [ ] Method names (`New`, `StartSessionAsync`, `Reconcile`, `Save`, `EndSession`, session-end hook) checked against the installed source; each TODO(verify-api) in architecture.md 3c and 6 resolved or corrected
- [ ] Result logged in docs/architecture.md and decisions.md
Status: todo (deferred, D-022: needs network/toolcheck; T-012 proceeds with TODO(verify-api))

### T-002 [integration] Verify AnalyticsService API (TODO(verify-api))   (S)  sprint: Mac  owner: integration-programmer
Depends on: owner `/toolcheck` pass
Acceptance criteria:
- [ ] Method names and parameters for onboarding funnel, funnel step, economy, custom and progression events checked against create.roblox.com/docs; limits noted
- [ ] architecture.md section 5 updated with the confirmed signatures (or "not available, fallback = custom events only")
- [ ] `TelemetryService` signatures in architecture.md 1b still match
Status: todo (deferred, D-022: needs create.roblox.com docs; T-033 is S2)

### T-018 [art] Glow Town hub: plaza, spawn, Sleepy Sid stage, Tool Stand, tags   (M)  sprint: Mac  owner: builder
Depends on: T-016
Acceptance criteria:
- [ ] Spawn faces Sleepy Sid 15 studs away, with a small foam pit; Tool Stand as a ShopStand; all parts tagged per architecture 1f
- [ ] Within part budgets (hub at most 6,000 parts); StreamingEnabled safe; every asset logged in docs/asset-briefs/asset-log.md
- [ ] No body-shape jokes; Sid has pillow hair and a yawn
- [ ] Minimal art (D-034): part-built, simple shapes; polish later
Status: todo (deferred, D-022: needs Studio/builder)

### T-019 [art] W1 boss models 1-4 (Sid, Benny, Sal, Captain Cardio) and stages   (M)  sprint: Mac  owner: builder
Depends on: T-018
Acceptance criteria:
- [ ] Models at most 150 parts, `ModelStreamingMode = Atomic`, `BossStage` tag with `BossId` and `WorldId`, 50 studs spaced along the stage row
- [ ] Jokes are outfit or prop only (GDD 11); no fart or burp gags; asset-log updated
Status: todo (deferred, D-022: needs Studio/builder)

### T-020 [art] W1 boss models 5-7 (Duke of Drip, Glow Queen, Aura Titan) and stages   (M)  sprint: Mac  owner: builder
Depends on: T-019
Acceptance criteria:
- [ ] Same rules as T-019; Aura Titan reads clearly as the world boss
Status: todo (deferred, D-022: needs Studio/builder)

### T-039 [art] Glow Pods 1-5 row, egg stands, Robux stand shells, Rebirth pad, "World 2 coming Saturday" portal sign   (M)  sprint: Mac  owner: builder
Depends on: T-018
Acceptance criteria:
- [ ] Pods tagged with `PodIndex`; Basic and Shiny egg stands; ShopStand `Robux` shell (opens UI only); no purchase pads, none on the tutorial path
- [ ] Minimal art (D-034)
Status: todo

### T-040 [art] Rank looks 1-6 and Starter Fit   (M)  sprint: Mac  owner: builder
Depends on: T-018
Acceptance criteria:
- [ ] Accessory sets named by look id in ServerStorage.Assets.Looks; at most 6 accessories each; aura = 1 emitter at rate 20 or less
- [ ] Cartoon only (GDD 11); asset-log updated
- [ ] Minimal art (D-034): simple part-built accessories and colour swaps are fine
Status: todo

### T-041 [art] Rank looks 7-12   (M)  sprint: Mac  owner: builder
Depends on: T-040
Acceptance criteria:
- [ ] Same rules as T-040; Rank 12 rainbow aura and crown
- [ ] Minimal art (D-034): same as T-040
Status: todo

### T-042 [art] W1 coin-egg pet models (Basic and Shiny, 10 pets)   (M)  sprint: Mac  owner: builder
Depends on: T-018
Acceptance criteria:
- [ ] Models at most 1,500 triangles each, named by pet id in ReplicatedStorage.Assets.Pets; free or own assets only, license logged; no paid assets
- [ ] Minimal art (D-034): simple part-built pets are fine
Status: todo

### T-061 [art] Mog Rings (2 in World 1, foam pits)   (M)  sprint: Mac  owner: builder
Depends on: T-039
Acceptance criteria:
- [ ] `MogRing` tags with `Side1`, `Side2`, `Pit`; ragdoll only lands inside the ring area; ring is readable on a phone
Status: todo

### T-065 [art] Robux egg pets (Star 4, Galaxy 4) and fixed-pet recolours (Sparkle Pup, Ring Light Retriever)   (M)  sprint: Mac  owner: builder
Depends on: T-042
Acceptance criteria:
- [ ] Sparkle Pup and Ring Light Retriever made as recolours plus an accessory on existing models; rarity readable at a glance
Status: todo

### T-080 [art] Game icon and thumbnails   (M)  sprint: Mac  owner: builder
Depends on: T-085
Acceptance criteria:
- [ ] Follows the marketer's brief; no red/green split face, no viral dance likeness, no real people; no "Minimal" claim
Status: todo

### T-022 [physics] Boss pose-off animation and boss ragdoll (local clone)   (M)  sprint: Mac  owner: physics-programmer
Depends on: T-021, T-019
Acceptance criteria:
- [ ] 3 s pose-off, then the boss ragdolls into the foam pit on a client-side clone; the real model is untouched
- [ ] Only players in the same world receive the effect; ragdoll clones are cleaned up (no leaks over 100 wins)
Status: todo (needs T-019 boss model and Studio)

### T-023 [physics] Spawn camera pan to Sleepy Sid   (S)  sprint: Mac  owner: physics-programmer
Depends on: T-021, T-018
Acceptance criteria:
- [ ] 2 s pan on first join, skippable by tap, never replays after FirstWin
Status: todo (needs T-018 hub and Studio)

### T-089 [physics] Studio tuning of ragdoll, rings and camera (duel ragdoll, boss ragdoll check, spawn pan)   (M)  sprint: Mac  owner: physics-programmer
Depends on: T-066, T-022, T-023, T-061
Acceptance criteria:
- [ ] Duel ragdoll lands in the real foam pit and always recovers; boss pose-off and pan work with the real models
- [ ] Fixes only inside src/client/Effects and src/shared/Physics; map issues go back to builder as notes in docs/asset-briefs/
Status: todo

### T-094 [integration] Studio full-game run: Rojo sync, play-through from spawn to first rebirth, hatch, duel, daily claim   (M)  sprint: Mac  owner: integration-programmer
Depends on: T-072, T-018, T-019, T-039
Acceptance criteria:
- [ ] `/toolcheck` passes; `main` syncs to the place; two-client run: first win, tool, pod, rebirth, egg, duel, daily reward, rejoin keeps data
- [ ] Bootstrap or contract fixes made; every failure that is not integration goes to its owner as a ticket or a docs/qa bug
Status: todo

### T-082 [qa] Full regression, exploit sweep and low-end mobile measurements   (M)  sprint: Mac  owner: qa
Depends on: T-094
Acceptance criteria:
- [ ] Every C->S remote fuzzed; Developer Console numbers measured against architecture section 7; 12-player server test; results in docs/qa/ with severity
- [ ] Lean v1 (D-034): focus on server exploits, the 2-client duel and the phone-size UI; skip the full 12-player run unless time remains
Status: todo

### T-083 [qa] Release checklist run   (S)  sprint: Mac  owner: qa
Depends on: T-082
Acceptance criteria:
- [ ] Zero open critical bugs; checklist signed in docs/qa/; owner playtest notes triaged into tickets
Status: todo

### T-084 [legal] Pre-launch Community Standards check   (S)  sprint: Mac  owner: lawyer
Depends on: owner or team-lead reads the live rules in a browser
Acceptance criteria:
- [ ] Live Community Standards plus the DevForum "Clarifying Requirements" post and live paid-random-items policy page read (D-019 #2); group Crew Cap, code wording, ladder wording and ragdoll content checked; result in docs/legal.md
- [ ] All [S] and [U] items in docs/legal.md re-checked; the Kids/Select requirements (age check, 2SV, fee or Plus, 16+ trial) confirmed as current; NL-1 status stated
- [ ] A pass, or a named fix list, handed to team-lead
Status: todo

### T-087 [gameplay] Balance pass and owner playtest fixes   (M)  sprint: Mac  owner: gameplay-programmer
Depends on: T-047, T-082
Acceptance criteria:
- [ ] EconomyConfig values retuned from qa sim and owner playtest notes; changes logged in decisions.md; pacing still matches GDD 4.7 within 20%
- [ ] Only after the owner playtest; value changes only
Status: todo

### T-086 [integration] Release candidate merge and publish checklist   (S)  sprint: Mac  owner: integration-programmer
Depends on: T-083
Acceptance criteria:
- [ ] `main` merged, tagged and playable; checklist of manual owner steps (save place, create products, set maturity questionnaire, group, age check) in docs/; nothing published by agents
Status: todo

---

## Update 1 (Saturday): World 2
Not in today's build (D-034). World 2 bosses 8-13, W2 pets, W2 map, portal teleport and Rebirth 3 unlock. Folder rule still applies when it is scheduled.

### T-051 [gameplay] World 2 gameplay wiring   (S)  sprint: Update 1  owner: gameplay-programmer
Depends on: T-031, T-060
Acceptance criteria:
- [ ] Boss, shop, pod, egg and Idle logic work in World 2 data (6 bosses, tools 9-12, pods 6-7, 3 eggs); `M_CLAMP` per world
Status: todo

### T-060 [art] World 2 Neon Runway map, portal and hub   (M)  sprint: Update 1  owner: builder
Depends on: T-039
Acceptance criteria:
- [ ] Portal to W2 (tagged `Portal`), W2 Spawn, boss row, pods 6-7, egg stands, Robux shop shell; within part budgets; asset-log updated
Status: todo

### T-062 [art] W2 boss models 8-10 (Laser Larry, DJ Dazzle, Chrome Champ)   (M)  sprint: Update 1  owner: builder
Depends on: T-060
Acceptance criteria:
- [ ] Same rules as T-019
Status: todo

### T-063 [art] W2 boss models 11-13 (Runway Rex, Diva Supreme, King Shine)   (M)  sprint: Update 1  owner: builder
Depends on: T-062
Acceptance criteria:
- [ ] Same rules as T-019; King Shine reads as the world boss
Status: todo

### T-064 [art] W2 coin-egg pets (Neon and Runway, 10 pets)   (M)  sprint: Update 1  owner: builder
Depends on: T-042
Acceptance criteria:
- [ ] Same rules as T-042
Status: todo

### T-090 [gameplay] EconomyConfig Neon and Runway eggs and W2 pets (split from T-027)   (S)  sprint: Update 1  owner: gameplay-programmer
Depends on: T-027
Acceptance criteria:
- [ ] Weights sum to 10,000 per egg; `validate()` asserts them
- [ ] Odds shown by the egg UI come from the same table
Status: todo

### T-091 [gameplay] World 2 unlock at Rebirth 3 (split from T-031)   (S)  sprint: Update 1  owner: gameplay-programmer
Depends on: T-031
Acceptance criteria:
- [ ] `World2Unlocked` set at Rebirth 3, saved, shown by the HUD
- [ ] Existing players who already hit Rebirth 3 are unlocked on login
Status: todo

### T-092 [world] Portal teleport and `teleportToWorld` (split from T-038/T-059)   (S)  sprint: Update 1  owner: world-programmer
Depends on: T-038, T-060
Acceptance criteria:
- [ ] Portal `Touched` checks the unlock on the server, then teleports; WorldId attribute updates; works after respawn
Status: todo

### T-093 [art] W2 Mog Rings (2, foam pits)   (S)  sprint: Update 1  owner: builder
Depends on: T-060
Acceptance criteria:
- [ ] Same rules as T-061
Status: todo

---

## Update 2 / later: polish and nice-to-haves (D-034)
Cut from today's build; do only if time remains after the Mac session.

### T-037 [systems] LeaderboardService (Lifetime MP, Rebirths)   (M)  sprint: Update 2  owner: systems-programmer
Depends on: T-012, T-018
Acceptance criteria:
- [ ] OrderedDataStores for Lifetime MP and Rebirths; at most 4 writes per player per 60 s; top 50 read every 120 s; integer values
- [ ] Hub board and top-3 podium data exposed for the builder's boards
Status: todo

### T-067 [physics] Mobile effects performance pass   (M)  sprint: Update 2  owner: physics-programmer
Depends on: T-043, T-044, T-045
Acceptance criteria:
- [ ] Effects at most 2 ms per frame and particles at most 300 on the smallest test device with 12 players; numbers recorded in docs/qa/
Status: todo

### T-070 [marketing] Launch-audience plan for the 16+ trial period   (S)  sprint: Update 2  owner: marketer
Depends on: none
Acceptance criteria:
- [ ] docs/marketing/ plan for a 16+ age-checked audience (older siblings, meme-clicker fans), with a no-paid-ads default (any ad spend is gate 3 and needs NL-1 clearance first)
- [ ] States how first-week data is read given the 16+ audience
Status: todo

### T-074 [gameplay] RewardService: codes (AURAUP)   (S)  sprint: Update 2  owner: gameplay-programmer
Depends on: T-052
Acceptance criteria:
- [ ] `RedeemCode` 1..20 alphanumeric, upper-cased, server list only, once per profile, 10 wrong in 10 min gives a 10 min lockout; AURAUP = 500 coins + 10 min Hype Snack
- [ ] The codes box wording is only "New codes at like and visit milestones"
Status: todo

### T-075 [systems] Donations: tips 5-1,000 R$ and Top Donors board   (M)  sprint: Update 2  owner: systems-programmer
Depends on: T-056, T-037
Acceptance criteria:
- [ ] Tip listing text exactly "Thank-you banner + donor name-tag colour. No other in-game benefit."; board shows names and rank only, no amounts, with an opt-out
Status: blocked (tips are not in the D-038 approval; needs a new owner price approval)

### T-076 [systems] Group Crew Cap (IsInGroup check, cosmetic only)   (S)  sprint: Update 2  owner: systems-programmer
Depends on: T-012, T-084
Acceptance criteria:
- [ ] Button text exactly "Join our group for update news + a free Crew Cap"; server `IsInGroup` check at join and on claim; never next to a like or favorite message; config flag to switch to news-only
Status: blocked (owner decision on GDD Q8, group id, and the Community Standards read in T-084)

### T-077 [systems] Mobile UI polish pass   (M)  sprint: Update 2  owner: systems-programmer
Depends on: T-072
Acceptance criteria:
- [ ] All screens usable on a phone-size emulator and a gamepad; no overlapping buttons; client UI at most 1 ms per frame; owner playtest UI notes fixed
Status: todo

### T-078 [world] Streaming and zone robustness pass   (S)  sprint: Update 2  owner: world-programmer
Depends on: T-072
Acceptance criteria:
- [ ] Nothing assumes a part is streamed in; portal, ring and pod checks survive respawn and rejoin; bugs from docs/qa/ fixed
Status: todo

### T-079 [art] Exclusive cosmetics: Golden Glow Fit, Neon Icon Fit, Crew Cap, VIP Sparkle Aura, Rookie Shades, Week Streak Aura   (M)  sprint: Update 2  owner: builder
Depends on: T-041
Acceptance criteria:
- [ ] Cosmetic only, no stats; own or free-licensed assets with license logged; no paid assets
Status: todo

---

## Conditional work (only if the owner picks B-1 option B)
Not used: the owner chose option A (D-021). Kept for reference only.

## GDD v1 feature map (lean v1, D-034)
| GDD feature | Tickets |
|---|---|
| Tap, MP, multiplier | T-006..T-008, T-014 |
| Bosses, coins, ragdoll (W1, 7 bosses) | T-009, T-019, T-020, T-022, T-089 |
| Tools and pods | T-010, T-015, T-030, T-034, T-039 |
| Rebirth (W2 portal sign only) | T-031, T-034, T-039 |
| Auto-Tap and Auto-Mog | T-030 |
| Eggs, pets, odds, pity (W1) | T-027, T-028, T-035, T-036, T-042, T-044, T-045, T-065, T-073 |
| PolicyService gate and B-1 | T-013, T-029, T-058 |
| Ranks, looks, D-033 | T-011, T-038, T-040, T-041, T-043, T-088 |
| Duels and ragdoll | T-049, T-050, T-054, T-059, T-061, T-066, T-068, T-089 |
| Monetization (shop, ladder, Robux eggs) | T-003, T-053, T-056..T-058, T-069, T-073, T-081 |
| Daily reward and quests | T-032, T-052, T-055 |
| Analytics | T-002, T-033 |
| Tutorial and first 5 minutes | T-014, T-023, T-032 |
| Saving | T-001, T-012, T-046 |
| Compliance and launch | T-005, T-071, T-084, T-085, T-086 |
| World 2 | Update 1 (T-051, T-060, T-062..T-064, T-090..T-093) |
| Leaderboards beyond leaderstats, codes, donations, Crew Cap, cosmetics, polish | Update 2 / later |

## Cut list (moved out of v1; first to go if the Mac session overruns)
1. Update 1 (Saturday): all World 2 work (see section above).
2. Update 2 / later: T-037 leaderboards (leaderstats stay), T-067 mobile effects pass, T-070 16+ audience plan, T-074 codes, T-075 donations and Top Donors, T-076 Crew Cap, T-077 UI polish, T-078 streaming pass, T-079 exclusive cosmetics.
3. Speed Sneakers, Neon Pup, Week Streak Aura, VIP Sparkle Aura.
4. If sprint 3 overruns, cut in this order: hatch x3 and equip-best, Starter Pack pop-up, T-050 anti-grief extras (keep reward caps), rank looks 7-12 (T-041).
5. If monetization stays blocked past the Mac session: ship v1 free-only, keep T-053, T-056..T-058, T-069, T-073, T-081 for the next update (a GDD pillar change, so escalate first).
6. From GDD section 12 "Not in v1": trading, pet fusing, ranked ELO, Ascend, co-op bosses, runway slots, MP packs, potions, enchants, friend referrals, Discord links; weekly events and World 3.
