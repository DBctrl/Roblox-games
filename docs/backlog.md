# Backlog
_Owned by project-manager. Ticket format: see .claude/agents/project-manager.md. Source: docs/gdd.md v1 (DRAFT, awaiting owner approval, D-007), docs/architecture.md v1 (D-009), lawyer rulings D-008 (not yet owner-approved)._

**Plan:** 3 sprints of ~1 week (week 4 = buffer for fixes/owner playtest feedback). Contract tickets (integration, EconomyConfig, PlotLayout) come first in sprint 1.
**Folder rule check:** within a sprint each folder has one writer: Contracts=integration; Gameplay+shared/Gameplay=gameplay; World+shared/World=world; Effects+shared/Physics=physics; UI+Data=systems; map/assets=builder; tests=qa. Cross-folder use is read-only via documented APIs.
**Toolchain not yet verified on the owner's Mac: no Studio/Rojo/Wally ticket can start until /toolcheck passes.**


## M1 Playable core loop (sprint 1)

### T-001 [integration] Add ProfileStore via Wally and verify API names   (S)  sprint: 1  owner: integration-programmer
Depends on: none
Acceptance criteria:
- [ ] `wally search profilestore` confirms scope/name/version; `wally.toml` updated; `wally install` OK
- [ ] Method names (StartSessionAsync, Reconcile, Save, EndSession, OnSessionEnd) checked; TODO(verify-api) in architecture.md resolved or corrected
- [ ] Result logged in docs/architecture.md
Status: todo

### T-002 [integration] Shared NumberFormat (K/M/B/T)   (S)  sprint: 1  owner: integration-programmer
Depends on: none
Acceptance criteria:
- [ ] `src/shared/Contracts/NumberFormat.luau`, --!strict, pure function
- [ ] 1500 -> 1.5K, 6e6 -> 6M, 1.536e9 -> 1.5B, <1000 unchanged, NaN/negative safe
- [ ] Passes StyLua and Selene
Status: todo

### T-003 [integration] Shared RateLimit helper   (S)  sprint: 1  owner: integration-programmer
Depends on: none
Acceptance criteria:
- [ ] `src/shared/Contracts/RateLimit.luau`: per-player `os.clock()` limiter, `check(player, key, interval)`, `clear(player)`
- [ ] Documented in architecture.md; usage example for C->S handlers
Status: todo

### T-004 [integration] MonetizationConfig skeleton (pass tiers, donation tiers)   (S)  sprint: 1  owner: integration-programmer
Depends on: none
Acceptance criteria:
- [ ] `src/shared/Contracts/MonetizationConfig.luau`: tiers 1-4 -> multipliers 2/4/8/16, donation tiers 1-5; product/pass ids = 0 placeholders
- [ ] No ids or prices committed as final; owner fills ids after approval (T-039)
Note: blocked on owner approval of prices (GDD gate)
Status: todo

### T-005 [gameplay] EconomyConfig (all balance constants + pure functions)   (M)  sprint: 1  owner: gameplay-programmer
Depends on: none
Acceptance criteria:
- [ ] `src/shared/Gameplay/EconomyConfig.luau` matches architecture section 1b: START_CASH, DROPPERS (10), UPGRADES, PAD_ORDER, BADGE_IDS, interval/glazeMult/rebirthMult/rebirthCost/padCost
- [ ] Values equal GDD section 5 tables (costs, values, intervals, glaze, 6M x 2^(n-1))
- [ ] No Roblox services required (pure)
Note: Contract-like: PlotService and UI read it, so it lands first in sprint 1.
Status: todo

### T-006 [world] PlotLayout accessors + map naming spec   (S)  sprint: 1  owner: world-programmer
Depends on: none
Acceptance criteria:
- [ ] `src/shared/World/PlotLayout.luau` implements architecture 1b accessors, nil-safe under StreamingEnabled
- [ ] Exact child names listed in summary for builder (T-007)
Status: todo

### T-007 [art] Builder: 6-plot template + candy hub, spawn, gate signs   (M)  sprint: 1  owner: builder
Depends on: T-006
Acceptance criteria:
- [ ] 6 plot Models tagged `Plot`, attr PlotId 1-6, `ModelStreamingMode=Atomic`, children per PlotLayout
- [ ] Hub with spawn; arrow/glow gates; plots face hub; parts within budget (plot <= 1,200; hub <= 3,000)
- [ ] Inserted assets logged in docs/asset-briefs/asset-log.md
Status: todo

### T-008 [art] Builder: droppers 1-5, conveyor path, seller   (M)  sprint: 1  owner: builder
Depends on: T-006, T-007
Acceptance criteria:
- [ ] Dropper Models `1`..`5` each with Attachment `Spout`; Conveyor Attachments `P1..Pn`; Seller part
- [ ] Pads folder has one pad part per PadId in EconomyConfig order
Status: todo

### T-009 [world] PlotService: claim gate, auto-claim at 20 s, ownership, release on leave   (M)  sprint: 1  owner: world-programmer
Depends on: T-006, T-007
Acceptance criteria:
- [ ] Touching a free gate claims the plot; nearest free plot auto-claimed at 20 s; `PlotClaimed`/`PlotReleased` fire
- [ ] Player attr PlotId and plot attrs set; one plot per player; plot resets on leave
- [ ] Works with 6 players joining at once; no second claim possible
Status: todo

### T-010 [world] PlotService: pad touch, 0.5 s debounce, reveal next 2 pads, setProgress   (M)  sprint: 1  owner: world-programmer
Depends on: T-005, T-006, T-009
Acceptance criteria:
- [ ] `PadTouched` fires only for owner and Available pads; other players do nothing
- [ ] `setProgress` sets PadState/PadLevel and reveals only the next 2 pads in PAD_ORDER
- [ ] Re-applying the same progress is idempotent
Status: todo

### T-011 [systems] DataService core: ProfileStore session, Data API, attributes, leaderstats   (M)  sprint: 1  owner: systems-programmer
Depends on: T-001
Acceptance criteria:
- [ ] Data API per architecture section 3 (getData, addCash, trySpendCash, update, waitForData, signals)
- [ ] Profile schema v1 with Reconcile; Cash/Rebirths attributes + leaderstats written only here
- [ ] Load failure kicks player with a friendly message
Status: todo

### T-012 [systems] HudController: Cash, $/s, onboarding hint   (M)  sprint: 1  owner: systems-programmer
Depends on: T-002, T-011
Acceptance criteria:
- [ ] Cash and $/s with K/M/B/T; waits for DataLoaded
- [ ] Arrow/text hint until PlotId > 0 ("Walk into a gate to claim a factory!")
- [ ] Readable on phone and tablet; UI <= 1 ms/frame
Status: todo

### T-013 [systems] NotificationController (toast queue)   (S)  sprint: 1  owner: systems-programmer
Depends on: none
Acceptance criteria:
- [ ] Handles `Notify`; max 3 visible; Info/Error styles
Status: todo

### T-014 [gameplay] IncomeService: 1 Hz tick, multipliers, income attributes   (M)  sprint: 1  owner: gameplay-programmer
Depends on: T-005, T-009, T-011
Acceptance criteria:
- [ ] Per-dropper accumulator; Cash credited server-side via `DataService.addCash`
- [ ] Exposes getIncomePerSecond/getBaseIncomePerSecond/getTotalMultiplier/refresh; sets IncomePerSec/TotalMultiplier attrs
- [ ] 6 players x 10 droppers: server script time <= 5%
Status: todo

### T-015 [gameplay] PurchaseService: dropper purchases (server validated)   (M)  sprint: 1  owner: gameplay-programmer
Depends on: T-010, T-011, T-014
Acceptance criteria:
- [ ] Consumes `PadTouched`; validates profile, ownership, next-in-order, `trySpendCash`
- [ ] Calls `DataService.update`, `PlotService.setProgress`, `IncomeService.refresh`, `PlayEffect("Purchase")`
- [ ] "Not enough Cash" Notify max 1 per 2 s
- [ ] First dropper free; Jellybean affordable at ~45 s
Status: todo

### T-016 [physics] CandyController + CandyConfig: pooled client belt candy   (M)  sprint: 1  owner: physics-programmer
Depends on: T-006, T-008
Acceptance criteria:
- [ ] Candy rides conveyor path spout -> seller, max 40 per plot, only plots within 200 studs
- [ ] Anchored, no collide/touch/query, one loop with BulkMoveTo, no per-candy connections
- [ ] Effects <= 2 ms/frame on low-end mobile
Status: todo

### T-017 [physics] EffectsController: seller +$ pop, purchase and claim effects   (M)  sprint: 1  owner: physics-programmer
Depends on: T-015
Acceptance criteria:
- [ ] `PlayEffect` handler for PlotClaimed and Purchase; "+$" pop and coin sound at seller on income
- [ ] <= 200 particles, <= 8 sounds; cosmetic only
Status: todo

### T-018 [qa] Test project + unit tests for pure modules   (M)  sprint: 1  owner: qa
Depends on: T-002, T-003, T-005
Acceptance criteria:
- [ ] `test.project.json` syncs /tests only
- [ ] Tests cover EconomyConfig tables vs GDD, NumberFormat, RateLimit
Status: todo

### T-019 [qa] M1 smoke test: core loop, 2+ players   (S)  sprint: 1  owner: qa
Depends on: T-012, T-015, T-016, T-017
Acceptance criteria:
- [ ] Claim -> first cash < 15 s -> Jellybean purchase < 60 s, 2 players no cross-plot interference
- [ ] Report in docs/qa/; milestone gate: owner /playtest (agents never judge fun)
Status: todo


## M2 Progression + saving (sprint 2)

### T-020 [gameplay] Machine upgrades: Faster Gears and Sugar Glaze (3 levels)   (S)  sprint: 2  owner: gameplay-programmer
Depends on: T-015
Acceptance criteria:
- [ ] Upgrade pads appear after Dropper 4 / 5; costs and effects from EconomyConfig
- [ ] Income recalculated via refresh; max level 3 enforced server-side
Status: todo

### T-021 [gameplay] RebirthService + RequestRebirth handler   (M)  sprint: 2  owner: gameplay-programmer
Depends on: T-003, T-015
Acceptance criteria:
- [ ] Cost 6M x 2^(n-1); atomic reset in one `DataService.update` (cash 50, droppers 1, upgrades 0, rebirths +1)
- [ ] Handler type-checks, rate limit 1 per 2 s, server recomputes cost; RebirthCost attr
- [ ] Keeps rebirths, daily, stats, badges
Status: todo

### T-022 [world] Seller rebirth prompt + plot reset on rebirth/leave edge cases   (S)  sprint: 2  owner: world-programmer
Depends on: T-009, T-010
Acceptance criteria:
- [ ] `RebirthPromptTriggered` owner only; plot visuals reset via setProgress
- [ ] Leaving mid-purchase or full server leaves plots clean
Status: todo

### T-023 [gameplay] DailyRewardService + ClaimDailyReward handler   (M)  sprint: 2  owner: gameplay-programmer
Depends on: T-003, T-014
Acceptance criteria:
- [ ] 7-day streak, once per UTC day, resets after 48 h; server `os.time()` only
- [ ] Reward = base $/s x GDD seconds, min $100, never multiplied by pass; Daily* attrs
Status: todo

### T-024 [gameplay] BadgeAwardService (Welcome, First Rebirth, Rebirth 5, Rebirth 10)   (S)  sprint: 2  owner: gameplay-programmer
Depends on: T-021
Acceptance criteria:
- [ ] Idempotent via profile.badges; skips id 0
- [ ] Owner creates badges in Roblox (free within limits, else cut to 3)
Status: todo

### T-025 [systems] DataService persistence: autosave 60 s, leave, shutdown, migrations   (M)  sprint: 2  owner: systems-programmer
Depends on: T-011
Acceptance criteria:
- [ ] Save every 60 s, on leave, on shutdown; session-lock safe on server hop
- [ ] schemaVersion + migration stub; verified by rejoin test
Status: todo

### T-026 [systems] HUD rebirth bar/button + DailyRewardController popup   (M)  sprint: 2  owner: systems-programmer
Depends on: T-021, T-023
Acceptance criteria:
- [ ] Rebirth bar "Rebirth at $6M: +50% earnings forever"; button fires RequestRebirth
- [ ] Daily popup from Daily* attrs; claim fires ClaimDailyReward
Status: todo

### T-027 [systems] DataService: SetDonorPrivacy handler + HideFromDonorBoard   (S)  sprint: 2  owner: systems-programmer
Depends on: T-003, T-025
Acceptance criteria:
- [ ] Remote type-checked, 1 per 1 s, no-op if unchanged; persisted in settings
- [ ] Part of D-008 item 3 (owner decision pending)
Note: Only meaningful if owner approves the Donors board with opt-out.
Status: todo

### T-028 [systems] MonetizationService: pass tier checks and PassTierChanged   (M)  sprint: 2  owner: systems-programmer
Depends on: T-004, T-011
Acceptance criteria:
- [ ] `UserOwnsGamePassAsync` on join; `PromptGamePassPurchaseFinished` applies instantly
- [ ] Highest owned tier wins (x2/x4/x8/x16); PassTier attr; never stored
Note: blocked on owner approval of prices (GDD gate)
Status: todo

### T-029 [physics] PadVisualController, dropper idle animations, rebirth effect   (M)  sprint: 2  owner: physics-programmer
Depends on: T-020, T-021
Acceptance criteria:
- [ ] Pads tint green when local Cash >= cost
- [ ] Rebirth confetti via PlayEffect; budgets respected
Status: todo

### T-030 [art] Builder: droppers 6-10, Faster Gears and Sugar Glaze machines   (M)  sprint: 2  owner: builder
Depends on: T-008
Acceptance criteria:
- [ ] Models 6..10 with Spouts; 2 upgrade machines near seller
- [ ] Plot stays <= 1,200 parts, textures <= 512 px
Status: todo

### T-031 [qa] Save, rebirth and exploit tests   (M)  sprint: 2  owner: qa
Depends on: T-021, T-023, T-025
Acceptance criteria:
- [ ] Rejoin keeps cash/droppers/rebirths; server-hop no dupes
- [ ] Remotes: bad types, NaN, spam are rejected; client cannot grant Cash or buy out of order
Status: todo


## M3 Monetization + polish (sprint 3)

### T-032 [systems] ProcessReceipt for donations (idempotent by PurchaseId)   (M)  sprint: 3  owner: systems-programmer
Depends on: T-004, T-025, T-028
Acceptance criteria:
- [ ] Only `ProcessReceipt` assignment in the project; PurchaseId stored in receipts (last 50)
- [ ] Returns PurchaseGranted only after profile saved; stats.robuxDonated updated
Note: blocked on owner approval of prices (GDD gate)
Status: todo

### T-033 [gameplay] Apply pass multiplier in IncomeService   (S)  sprint: 3  owner: gameplay-programmer
Depends on: T-028
Acceptance criteria:
- [ ] PassMult applied on PassTierChanged via refresh; daily reward unaffected
- [ ] Highest-tier rule verified for all four tiers
Note: blocked on owner approval of prices (GDD gate)
Status: todo

### T-034 [systems] ShopController: pass ladder, donations, D-008 shop rules   (M)  sprint: 3  owner: systems-programmer
Depends on: T-028, T-032
Acceptance criteria:
- [ ] Hides/disables tiers at or below owned tier; text "does not stack; the highest one you own applies"
- [ ] Donate menu: "Donations support the developer and give no in-game advantage"; neutral wording, no fake urgency
- [ ] Optional donor-board opt-out toggle (T-027)
Note: blocked on owner approval of prices (GDD gate)
Status: todo

### T-035 [systems] LeaderboardService: Rebirths, Total Cash, Top Donors   (M)  sprint: 3  owner: systems-programmer
Depends on: T-002, T-025, T-027
Acceptance criteria:
- [ ] 3 OrderedDataStores, writes <= every 60 s if changed, top 50 read
- [ ] Donors board: names and rank only, skips opted-out (pending owner decision on D-008 item 3)
Status: todo

### T-036 [art] Builder: 3 leaderboard boards, small SFX/UI icon set   (S)  sprint: 3  owner: builder
Depends on: T-007
Acceptance criteria:
- [ ] Boards tagged `Leaderboard` with Board attr
- [ ] Only free/owned SFX; logged in asset-log.md
Status: todo

### T-037 [physics] Donation and pass effects (confetti, fireworks, sparkle)   (S)  sprint: 3  owner: physics-programmer
Depends on: T-032
Acceptance criteria:
- [ ] `Donation` PlayEffect tiers 1-5; opted-out donor shows no name
- [ ] Within particle budget
Note: blocked on owner approval of prices (GDD gate)
Status: todo

### T-038 [qa] Mobile performance and budget pass   (M)  sprint: 3  owner: qa
Depends on: T-029, T-034
Acceptance criteria:
- [ ] Developer Console on smallest test device: memory <= 700 MB, frame budgets from architecture section 5
- [ ] Report with fixes assigned
Status: todo


## M4 Launch (sprint 3)

### T-039 [integration] Fill pass/product/badge ids; release candidate merge   (S)  sprint: 3  owner: integration-programmer
Depends on: T-032, T-033, T-034
Acceptance criteria:
- [ ] Owner-created pass and product ids entered in MonetizationConfig; BADGE_IDS filled
- [ ] Release candidate merged to `main`
Note: blocked on owner approval of prices (GDD gate)
Status: todo

### T-040 [art] Marketer: thumbnail, icon, game description   (S)  sprint: 3  owner: marketer
Depends on: none
Acceptance criteria:
- [ ] Neutral wording (no "pay to win"); no third-party IP; no spend or ads without owner approval
Status: todo

### T-041 [qa] Launch regression + legal re-check + maturity questionnaire checklist   (S)  sprint: 3  owner: qa (lawyer input)
Depends on: T-038, T-039
Acceptance criteria:
- [ ] Full core loop to rebirth + purchase flows pass
- [ ] docs/legal.md re-verified against live Roblox policy pages; maturity questionnaire prepared for owner
- [ ] Owner publishes (human gate); agents never publish
Status: todo


## Cut list (moved out of v1)
- Group +10% earnings bonus: removed per D-008 (optional no-reward "join group" button only, if owner wants).
- Top Donors board Robux amounts: names/rank only; whole board cut if owner rejects D-008 item 3 (T-027, T-035 part).
- Offline earnings, second floor/plot expansion, free-placement building, pets/crates/eggs, trading, quests, events/seasons.
- Auto-Rebirth pass, VIP pass, x32+ multiplier tiers, rebirth shop/tokens, plot themes, friend bonus, codes.
- Console UI polish, localisation, anti-AFK, NPC customers, extra SFX beyond a small free set.
- Badges: if Roblox limits bite, cut to 3 (T-024).
- Fallback if sprint 3 slips: drop T-037, T-040 polish, then leaderboard boards (T-035, T-036).
