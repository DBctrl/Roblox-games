Toolchain: NOT VERIFIED (run ./scripts/doctor.sh, then /toolcheck on the Mac)

# Status
_Owned by project-manager. One screen. Updated 2026-10-31._

**Game:** "Aura Up!" (working title), mog clicker | **Stage:** GDD approved, sprint 1 waiting on toolchain | **Milestone:** M1 not started | **Sprint:** 0 of 4 | **Plan:** 87 tickets, about 4 weeks (3 build + 1 buffer), then the 16+ trial

## Sprint
S1 = M1 core loop (26 tickets) | S2 = M2 progression + saving (22) | S3 = M3 duels, W2, monetization, polish (24) | S4 = M4 buffer, QA, launch kit (15). Details: docs/backlog.md.

## Done
- Studio set up; marketing brief + competitor research; GDD rev 1 (D-018); lawyer review + re-check (D-016, D-019); architecture v1 (D-017); backlog T-001..T-087 (old Candy Factory backlog superseded, D-011)
- T-005 legal re-review (D-019)
- Owner approved GDD rev 1 and B-1 option A (D-021): Robux never buys coins, 23 products, coin eggs open to all

## In progress
- Nothing. Waiting on owner toolchain setup.

## Blocked (who can unblock)
- All S1 build tickets: toolchain verification (owner)
- Monetization tickets T-053, T-056, T-057, T-058, T-069, T-071, T-073, T-075, T-081: owner price approval (gate 5), then the owner creates the 23 developer products. Build may use GDD placeholder prices; nothing goes live
- T-053 ladder-receipt fix (D-019 #3, Hype Snack fallback) waits for the price review
- T-076 Group Crew Cap: owner decision (GDD Q8), group id, Community Standards read (T-084)

## Needs owner
1. Run ./scripts/doctor.sh then `/toolcheck` on the Mac: stylua and selene are missing; Rojo plugin and Studio MCP are not set up
2. Approve prices before the end of S1 (gate 5); also ladder top, odds, VIP pet slot, title, event time, group reward, Kids/Select fee, rank names
3. Start the creator age check and 2-Step Verification now (long lead time, R-1)
4. Get a trademark clearance search for the title (NL-1) before any ad spend

## Risks
- **16+ trial period (R-1):** at launch the 9-14 target audience cannot see the game; first-week data comes from 16+ players until 250 engaged plays in 60 days and a safety review pass. Possible about 1,000 R$ fee (unverified, gate 3). Marketing plans for 16+ (T-070)
- **Toolchain unverified:** stylua/selene missing, Rojo and Studio MCP not set up; Rojo, Wally, ProfileStore and AnalyticsService APIs may differ (T-001, T-002) and delay S1
- Gameplay-programmer is the bottleneck (about 5 days of work per sprint in S1-S3); overflow moves to the S4 buffer, then the cut list
- Monetization chain (T-069 to T-075) is on the M3 critical path: prices should be approved by end of S1
- Live Roblox policy pages could not be opened by agents; the Community Standards read (T-084) is a manual step
- Mobile performance budgets; all prices are PROPOSED
