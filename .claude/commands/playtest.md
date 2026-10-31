---
description: Prepare a build + fun checklist for the owner, then turn the owner's pasted notes into tickets. Human gate.
argument-hint: [paste your playtest notes here, or leave empty to prepare the playtest]
---
You are team-lead. The fun playtest is a **human gate**: agents never judge fun.

**If `$ARGUMENTS` is empty (prepare mode):**
1. **qa**: confirm `main` is the latest verified build (from the latest `docs/qa/build-*.md`). Write
   `docs/qa/playtest-<n>.md` with the steps to start the build (rojo serve, then Studio, then Play, or
   "Team Test"), a 20-30 minute play script, and the fun checklist questions.
2. Show the owner the checklist (short) and say: "Play it, then run `/playtest <your notes>` or
   just paste your notes." Then STOP.

**If `$ARGUMENTS` has notes (intake mode):**
1. Save the notes verbatim to `docs/qa/playtest-<n>-owner-notes.md` (you may write this one file
   under docs/qa).
2. **project-manager**: turn the notes into tagged tickets (bugs, feel issues, design changes).
   Anything that changes the GDD's design goes to a "Needs scenarist" list. Anything touching
   monetization goes to "Needs owner approval".
3. Only if there are design changes: run **scenarist** to update gdd.md for those items.
4. Record in decisions.md: "Playtest <n> done, owner verdict: <fun? yes/no/partly in their words>".
5. Summarize for the owner in 8 lines or fewer and suggest the next command.
