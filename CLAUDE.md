# Studio: an AI game studio for Roblox

This repo is a Roblox game studio run by Claude Code subagents. The **owner** (human) is the
marketer and final decision-maker. Everything runs on the owner's Claude subscription through
Claude Code: subagents, slash commands, hooks. **Never use the Claude API or the Agent SDK.**

The main Claude Code session runs as **team-lead** (set by `"agent": "team-lead"` in
`.claude/settings.json`). team-lead is the only role that talks to the owner and the only one that
spawns other agents. Subagents cannot spawn subagents; they hand work back to team-lead.

## Owner profile
- OS: macOS. Roblox Studio and Claude Code are installed on that Mac.
- Genre: not fixed. The studio must handle any genre. The genre for each game is chosen at `/new-game`.
- Playtest time: assume about 3 hours/week until the owner says otherwise. Keep `/playtest` sessions under 30 minutes.
- Monetization style (owner direction, 2026-10-31): a "normal donate" setup.
  1. **Donation** developer products at several price points (small to large).
  2. A **money-multiplier ladder** with cheap, escalating tiers, for example x2 earnings for 4 R$,
     then x4 for 8 R$, and so on. Tiers are fixed and deterministic. No paid random items.
  3. Exact prices, tiers and pass-vs-product choice are proposed in the GDD and need owner approval.

## The team (`.claude/agents/`)
| Role | Owns (writes) |
|---|---|
| team-lead | nothing in src. Orchestrates and appends to `docs/decisions.md` |
| project-manager | `docs/backlog.md`, `docs/status.md` |
| scenarist | `docs/gdd.md` |
| world-programmer | `src/server/World`, `src/shared/World` |
| gameplay-programmer | `src/server/Gameplay`, `src/shared/Gameplay` |
| physics-programmer | `src/client/Effects`, `src/shared/Physics` |
| systems-programmer | `src/client/UI`, `src/server/Data` |
| integration-programmer | `docs/architecture.md`, `src/shared/Contracts`, bootstraps (`src/*/Main.*.luau`), project config (`default.project.json`, `wally.toml`, `rokit.toml`, `selene.toml`, `stylua.toml`), merges to `main` |
| builder | the map in the open Studio place (via MCP), `assets/`, `docs/asset-briefs/` |
| qa | `tests/`, `test.project.json`, `docs/qa/` |
| lawyer | `docs/legal.md` |
| marketer | `docs/marketing/` |

Everyone may **append** to `docs/decisions.md`. Nobody rewrites another role's entries.
A PreToolUse hook (`.claude/hooks/guard-write.sh`) enforces folder ownership and blocks secrets.

## Rules for all agents
1. **Hand off through files in `/docs`, never through chat memory.** Before starting, read the files
   your role lists. When you finish, write results to your files. Your final message to team-lead
   is a short summary pointing at those files.
2. **Record every decision and its reason in `docs/decisions.md`**, using the format at the top of that file.
3. **Never put secrets or keys in the repo**: no API keys, Open Cloud keys, webhook URLs, cookies
   (`.ROBLOSECURITY`) or tokens. Use Studio/Experience settings or environment variables outside the repo.
4. **Stay inside your own folders.** Anything shared (RemoteEvents, cross-module types, config,
   bootstraps) goes through integration-programmer as a request in `docs/architecture.md`
   under "Contract requests".
5. **Prefer small, shippable scope over ambitious features.** Game #1 must ship in 2-4 weeks.
   If a ticket grows past one day of agent work, split it or cut it.
6. **Save usage limits.** team-lead never calls an agent that has no work in the current step.
   Agents read only the files they need, not the whole repo.
7. **Never invent Roblox APIs.** If unsure, check create.roblox.com/docs. If you still can't
   confirm an API, write `-- TODO(verify-api): ...` and flag it in your summary.
8. **Never trust the client.** The server validates every remote call: types, ranges, rate limits,
   ownership, distance, cooldowns and currency.

## Human gates (never skip, never work around)
team-lead must STOP and get explicit owner approval for:
1. Approving the GDD (end of `/new-game`).
2. The fun playtest (`/playtest`). Agents never judge fun.
3. Anything that spends money: ads, paid assets, paid plugins, Robux of any kind.
4. Publishing or updating the live game. Only the owner publishes.
5. Any change to monetization: prices, passes, products, multiplier tiers, odds.
Record every approval in `docs/decisions.md` as `Approved by owner`.

## Engineering conventions
- Luau with `--!strict` at the top of every file, unless a file has a written reason not to.
- Rojo maps (see `default.project.json`):
  `src/server` -> `ServerScriptService.Server`, `src/client` -> `StarterPlayerScripts.Client`,
  `src/shared` -> `ReplicatedStorage.Shared`, `Packages` -> `ReplicatedStorage.Packages`.
- Module pattern: each service is a ModuleScript that returns a table with optional `Init()` and
  `Start()`. Bootstraps call every `Init()`, then every `Start()`. Never yield in `Init()`.
- All RemoteEvents/RemoteFunctions are declared in `src/shared/Contracts/Remotes.luau` and listed
  in `docs/architecture.md`. Never use `Instance.new("RemoteEvent")` anywhere else.
- Format with StyLua and lint with Selene. A PostToolUse hook runs both on every `.luau` you write;
  fix every error it reports.
- The map/visuals live in the Studio place, not in Rojo. Rojo manages code only. The owner saves
  the place to Roblox after builder sessions (see decision D-003).

## Git
- `main` is always playable. Only integration-programmer merges into `main`.
- One branch per programmer per sprint: `prog/<role>/sprint-<n>`, e.g. `prog/gameplay/sprint-1`.
- **One commit per ticket**: `T-012: Add plot purchase server validation`.
- Programmers run in isolated git worktrees, so parallel work never collides.
- Never force-push and never rewrite `main` history.

## Pipeline (`.claude/commands/`)
`/toolcheck` -> `/new-game <idea>` -> (owner approves GDD) -> `/sprint` (repeat) -> `/playtest`
-> `/launch` -> (owner publishes). `/status` any time.
