Toolchain: NOT VERIFIED (run ./scripts/doctor.sh, then /toolcheck on the Mac)

# Status
_Owned by project-manager. One screen. Updated 2026-10-31 (sprint 2 closed, sprint 3 started)._

**Game:** "Aura Up!" (working title), mog clicker | **Target:** today, lean v1 | **Stage:** Sprint 2 merged (main 159a05d, build 2); Sprint 3 in progress | **Milestone:** M1 and M2 done in code | **Plan:** 95 tickets, World 1 only (7 bosses)
**Code repo:** https://github.com/DBctrl/roblox-games (holds `main`; the Mac pulls from here)

## Sprint
Sprint 3 (duels + monetization, code only): gameplay T-095, T-032, T-049, T-050, T-052, T-053, T-073 | systems T-056..T-058, T-054, T-055 | world T-059 | physics T-066 | qa T-068, T-081 | integration T-069, then T-072 merge last | legal T-071 | marketing T-085. Next: Mac session (art, Studio run, playtest, publish). Update 1 = World 2, Update 2 = polish. Details: docs/backlog.md.

## Done
- GDD rev 2, B-1 option A (D-021), legal review, architecture v1.3, backlog
- Sprint 1 (D-032) and Sprint 2 (D-051) code merged; owner approved prices (D-038)
- Sprint 2 sim: QA-F6 closed (D-052)

## In progress
- Sprint 3 tickets above. Small gameplay item T-095 (rename `equipped` local in PetService.inventoryString; UID_MAX = 1e12-1).

## Blocked (who can unblock)
- Monetization go-live (T-053, T-056..T-058, T-069, T-073, T-081): code can be built now; going live needs the owner to create the 15 approved developer products in Creator Hub and give the ids (T-069)
- T-075 donation tips: tips were not in the D-038 approval; needs a new owner price approval (Update 2)
- Studio checks (T-001, T-002, all [art], T-022, T-023, T-089, T-094, Play-mode specs that SKIP, QA-1/QA-2 UI re-test): the Mac setup

## Needs owner
1. Mac setup: ./scripts/doctor.sh, `/toolcheck`, Rojo plugin, Studio MCP; pull `main` from DBctrl/roblox-games
2. Create the 15 developer products after sprint 3 (ids go in T-069)
3. Approve Speed Sneakers, Neon Pup, Neon Icon Fit and tips later if wanted (not in D-038)
4. Playtest (gate 2, under 30 min), then publish (gate 4)
5. Start the creator age check and 2-Step Verification now (16+ trial lead time)

## Risks
- **Bugs:** 11 items still listed Open in docs/qa/bugs.md; main shows a fix for each, qa has not closed them. QA-1 and QA-2 (UI) need a Studio check
- **Docs drift:** GDD section 8 still holds placeholder prices; scenarist should sync it to D-038 (T-071 lawyer reviews listings against it)
- **Gameplay load:** 7 tickets in sprint 3; cut order in the backlog Cut list
- **Integration risk:** three sprints of code merged before any Studio run; T-094 may find wiring bugs late
- **16+ trial (R-1)** and **unverified APIs** (ProfileStore, AnalyticsService) unchanged
