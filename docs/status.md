Toolchain: NOT VERIFIED (run ./scripts/doctor.sh, then /toolcheck on the Mac)

# Status
_Owned by project-manager. One screen. Updated 2026-10-31 (sprint 3 closed)._

**Game:** "Aura Up!" (working title) | **Stage:** Sprint 3 merged (build 3, SHIP-TO-OWNER, static checks only, no S1) | **Milestone:** M1-M3 done in code; M3 polish and M4 need the Mac | **Plan:** lean v1, World 1, 7 bosses
**Repo:** https://github.com/DBctrl/roblox-games (`main` is what the Mac pulls)

## Done today
- Sprints 1-3 code merged (D-032, D-051, D-069, D-071); qa fix rounds 1-2 in
- Applied: Starter Pack re-grant (D-060), Golden Glow Cat 3.20, Galaxy Egg in World 1 (D-057), QA-12, QA-F10, QA-F12 closed
- Lawyer listing review (T-071) and launch kit (T-085) done

## In progress (code, cloud)
- CR-I8 post-save hook: systems (MonetizationService runs it) and gameplay (PetService hatch message). Closes QA-14
- QA-13 duel log clock skew (S3, gameplay)

## Needs the Mac (order in docs/backlog.md "Mac session")
1 setup + /toolcheck (20 min) | 2 T-001/T-002 | 3 builder art incl. GalaxyEggStand, 2 MogRings, WeekStreakAura | 4 T-022/T-023/T-089 | 5 T-094 full run | 6 T-082/T-083 | 7 T-084 lawyer | 8 products + ids | 9 playtest | 10 T-087 | 11 T-086 RC | 12 publish. About 3 h owner time, about 7.5 h elapsed

## Needs owner
1. Clone the repo on the Mac, setup, `/toolcheck`
2. Create the 15 approved developer products and paste the ids (architecture 4f); not-approved: Speed Sneakers, Neon Pup, Neon Icon Fit, tips
3. Fun playtest (gate 2, under 30 min); then publish (gate 4)
4. Start the creator age check and 2-Step Verification now (16+ trial lead time)

## Risks
- Three sprints merged with no Studio run: T-094 may find wiring bugs late; Play-mode specs still SKIP
- Open bugs: QA-13, QA-14 (S3); QA-1, QA-2, QA-5, QA-8 look fixed in code, qa closes after a Studio check
- Product ids are placeholder 0: no purchase works until step 8
- Docs drift: GDD section 8 prices vs D-038 (D-070 synced part); unverified APIs (ProfileStore, AnalyticsService); 16+ trial (R-1)
