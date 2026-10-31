Toolchain: NOT VERIFIED (run ./scripts/doctor.sh, then /toolcheck on the Mac)

# Status
_Owned by project-manager. One screen. Updated 2026-10-31 (D-034)._

**Game:** "Aura Up!" (working title), mog clicker | **Target:** today (about 10 hours), lean v1 | **Stage:** Sprint 1 merged (D-032); next Sprint 2 (cloud, code only) | **Milestone:** M1 done in code, M2 next | **Plan:** 94 tickets total, World 1 only (7 bosses)

## Sprint
Sprint 2 = M2 core (gameplay T-088, T-027..T-031; systems T-033..T-036; world T-038; physics T-043..T-045; qa T-046, T-047; integration T-048) | Sprint 3 = duels + monetization (gameplay T-032, T-049, T-050, T-052, T-053, T-073; systems T-054..T-058; world T-059; physics T-066; qa T-068, T-081; integration T-069, T-072; legal T-071; marketing T-085) | Mac session = art, Studio run, playtests, publish | Update 1 (Saturday) = World 2 | Update 2 = polish. Details: docs/backlog.md.

## Done
- GDD rev 2 (D-033: Rank 2 at 1,800 MP), approved rev 1 and B-1 option A (D-021), legal review, architecture v1, backlog
- Sprint 1 code merged to main (D-032): contracts, Data, Gameplay core, World core, HUD, Effects, tests

## In progress
- Nothing running; Sprint 2 starts on team-lead's go. qa is still reviewing sprint 1 (more bugs may come, folded into Sprint 2 tickets)

## Blocked (who can unblock)
- Monetization go-live (T-053, T-056..T-058, T-069, T-071, T-073, T-081): owner price approval (gate 5), then owner creates the developer products. Code is built with placeholder prices and ids meanwhile
- Studio work (T-001, T-002, all [art], T-022, T-023, T-089, T-094): the Mac setup

## Needs owner
1. Mac setup: ./scripts/doctor.sh, `/toolcheck`, Rojo plugin, Studio MCP (needed for the Mac session)
2. Create a GitHub repo for the code (so the Mac can pull `main`)
3. Approve prices, ladder tiers and egg odds (gate 5) before the Mac session ends
4. Create the developer products in Creator Hub after price approval (ids go in T-069)
5. Playtest the game (gate 2, under 30 min), then publish (gate 4); only the owner publishes
6. Start the creator age check and 2-Step Verification now (16+ trial lead time)

## Risks
- **Usage limits:** two parallel cloud sprints plus the Mac session may hit subscription limits; cut order is in the backlog Cut list; gameplay is the heaviest role (6 tickets per sprint)
- **16+ trial (R-1):** at launch the 9-14 audience cannot see the game; first-week data comes from 16+ players; possible fee (gate 3)
- **Unverified APIs:** ProfileStore and AnalyticsService fall back to local adapters and TODO(verify-api) until the Mac session
- **Integration risk:** two sprints of code are merged before any Studio run; T-094 may find wiring bugs late
- Monetization may slip past today if prices are not approved; fallback is a free-only v1 (needs owner escalation)
