# Build 2 (sprint 2 merge)
_Build note from **integration-programmer** (T-048 merge). The guard-write hook blocks that role from `docs/qa/`,
so qa wrote it here on 2026-10-31 from team-lead's hand-off. qa's results go in `docs/qa/report-sprint2-r<n>.md`._

**Build:** `main` at `3b44bc3` plus the sprint-2 fix-round commits on top (first: `baae177`, D-052).
**Scope:** code only. No Studio run, no map change, no Luau type check (same rule as build 1, D-022).

## 1. Merge
All 5 sprint-2 branches merged into `main`:

| Branch | Merge commit |
|---|---|
| prog/world/sprint-2 | c38bf11 |
| prog/gameplay/sprint-2 | 5309f80 |
| prog/physics/sprint-2 | 5eddbb9 |
| prog/systems/sprint-2 | 969e1f3 |
| prog/qa/sprint-2 | beca6d7 |

Then T-048 `3b44bc3`: sprint-2 contract requests (CR-G2, CR-W2, CR-S2a-d) and the `PetInventory` attribute.
Decision renumbering and contract details: D-051, `docs/architecture.md` v1.3.

## 2. What was checked for this build
Static checks, lint and builds only:
- StyLua `--check` and Selene on `src/` and `tests/`.
- `rojo build default.project.json` and `rojo build test.project.json`.
- `tests/static/*.py` (handlers, authority, boss ids, each with its `--selftest`) and `tests/sim/timing_sim.py`.

Not checked in this build: anything that needs Studio (play mode, Studio specs in `tests/`, exploit pass with
real remotes, DataStore/receipt runs, device emulation, performance). Those wait for a Studio build.

## 3. Fix round 1 (qa)
- `check_authority.py`: the roll-function pattern matched `roll` inside `Ui.scrollList`
  (`src/client/UI/Util/Ui.luau`). It now matches only at the start of a function or identifier name; the selftest
  covers `scrollList`/`enroll` (pass) and `Egg.rollPet = function` (fail).
- `timing_sim.py`: ±15 s tolerance at two-sided band edges (D-052). QA-F6 closed.
