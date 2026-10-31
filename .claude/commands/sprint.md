---
description: Run one sprint - assign tickets, parallel programming on branches, builder, merge, full-game run, QA fix loop (max 3), status summary.
argument-hint: [optional focus, e.g. "M1 only"]
---
You are team-lead. Run one sprint. Focus: $ARGUMENTS

Preconditions (check before spawning anything):
- `docs/decisions.md` records owner approval of the GDD. If not, stop and ask for it.
- `docs/status.md` says "Toolchain: verified". If not, tell the owner to run `/toolcheck` and stop.

1. **project-manager**: pick this sprint's tickets (respecting dependencies, about 3-5 days of work),
   assign each to its role by tag, set the sprint number, and update backlog/status. Its summary
   must list, per role: ticket IDs, and whether any two roles touch the same folder (they must not).
2. **Programmers in parallel**: in ONE message, spawn only the programmers that have tickets
   (world-, gameplay-, physics-, systems-programmer), each with `isolation: "worktree"`.
   Brief: "Sprint <n>. Your tickets: T-... . Branch `prog/<role>/sprint-<n>`. One commit per
   ticket. Read your agent file for rules. Return: tickets done, files, contract requests."
   - If a contract change is needed **before** coding, run integration-programmer first for just
     that change, then the programmers.
   - **builder** works alongside world-programmer when there are [art] tickets. builder edits the
     Studio place directly (not git), so it can run in parallel with the code work.
3. Route any "Contract requests" to **integration-programmer**. Then integration-programmer merges
   all sprint branches into `main`, runs the full game through Studio MCP, and writes
   `docs/qa/build-<n>.md`. The owner needs `rojo serve` running and Studio open with the Rojo
   plugin connected. If it isn't, ask the owner and wait.
4. **qa**: test the build and write the report and `docs/qa/bugs.md`.
   **Fix loop**: if FIX-NEEDED, give each bug to the owning programmer (only those with bugs, in
   parallel, on the same sprint branch). Then integration-programmer re-merges and re-runs, then qa
   re-tests. **Max 3 rounds.** If S1/S2 bugs remain after round 3, stop and escalate to the owner
   with the bug list.
5. **project-manager**: mark tickets done/blocked, copy open bugs into the backlog, update status.md.
6. If builder worked on the map: remind the owner to **Save to Roblox** in Studio.
7. Reply to the owner in 10 lines or fewer: what's now playable, what slipped, blockers, what you
   need from them, and the recommended next command (`/sprint` again or `/playtest`).
