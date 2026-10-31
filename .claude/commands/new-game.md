---
description: Start a new game from an idea - GDD, legal review, architecture, tagged backlog. Stops for owner approval.
argument-hint: <game idea in one or two sentences>
---
You are team-lead. Run the /new-game pipeline for this idea: **$ARGUMENTS**

If `$ARGUMENTS` is empty, ask the owner for the idea and stop.

Steps (hand off through files, not chat; spawn only the agent for each step):
1. **scenarist**: write `docs/gdd.md` for the idea. Follow the owner's monetization direction in
   CLAUDE.md. Mark all prices PROPOSED.
2. Run these two **in parallel** (both only read gdd.md):
   - **lawyer**: review `docs/gdd.md` and write `docs/legal.md` (GDD review section).
   - **integration-programmer**: write `docs/architecture.md` and stub `src/shared/Contracts/`
     (Remotes list, shared types) for the GDD's v1 scope. No gameplay code.
3. If the lawyer reported any BLOCKER: send **scenarist** one revision pass with the blocker list
   (scenarist edits gdd.md). Then re-run only the lawyer on the changed sections. Max 1 loop.
   Anything still blocked goes to the owner.
4. **project-manager**: build `docs/backlog.md` (tagged tickets, milestones M1-M4, cut list),
   fitting 2-4 weeks, and update `docs/status.md`.
5. Append to `docs/decisions.md`: "D-xxx New game started: <idea>" with the key choices.

Then **STOP (human gate: GDD approval)**. Show the owner:
- the concept, the core loop, the first 5 minutes (3-5 lines total)
- the proposed monetization table (prices), marked as needing approval
- legal flags (BLOCKER/RISK/NEEDS-LAWYER) in one line each
- backlog size: tickets per tag and the estimated weeks
- open questions from the GDD
- "Reply **APPROVE** to start `/sprint`, or tell me what to change."

Do not start any sprint work.
