# Decisions log

Append only. Format:
`## D-xxx YYYY-MM-DD - <title>` then **By:** role. **Decision:** ... **Why:** ... **Approved by owner:** yes/no/n.a.

## D-001 2026-10-31 - Studio runs on Claude Code only
**By:** team-lead (setup). **Decision:** Roles are Claude Code subagents, the pipeline is slash commands, and guardrails are hooks. No Claude API or Agent SDK. The main session runs as team-lead via `"agent": "team-lead"` in .claude/settings.json, because subagents cannot spawn subagents. **Why:** owner requirement; everything stays on the owner's subscription. **Approved by owner:** yes (setup brief).

## D-002 2026-10-31 - Owner's monetization direction
**By:** owner. **Decision:** A "normal donate" setup: donation developer products, plus a cheap escalating money-multiplier ladder (example: x2 earnings for 4 R$, x4 for 8 R$, and so on). No paid random items. Exact tiers and prices are set per game in the GDD, and the owner approves them. **Why:** owner preference: low-pressure, cheap impulse buys. **Approved by owner:** yes (direction only; prices still need approval).

## D-003 2026-10-31 - Rojo manages code only; the map lives in the Studio place
**By:** team-lead (setup). **Decision:** Rojo syncs `src/` (scripts) only. Workspace has `$ignoreUnknownInstances: true`, so Rojo never deletes builder's map. builder edits the place through Studio MCP, and the owner saves the place to Roblox after builder sessions. Every inserted asset is logged in docs/asset-briefs/asset-log.md. **Why:** building maps as code is slow and ugly, and Studio's place version history gives us map history. **Approved by owner:** n.a.

## D-004 2026-10-31 - Tests live in /tests, synced only by test.project.json
**By:** team-lead (setup). **Decision:** Adds `/tests` (owned by qa) to the requested layout, so test code never ships in the live place. **Why:** keep production builds clean. **Approved by owner:** n.a.

## D-005 2026-10-31 - Cheaper model for PM and marketer
**By:** team-lead (setup). **Decision:** project-manager and marketer use `model: sonnet`. All other roles inherit the session model. **Why:** saves usage limits on text-heavy roles where the top model adds little. **Approved by owner:** n.a. (change in the agent files if you prefer).

## D-006 2026-10-31 - Genre is chosen per game
**By:** owner. **Decision:** The owner answered "all" for genre. The studio stays genre-agnostic, and the genre is fixed by the idea given to /new-game. **Why:** owner answer. **Approved by owner:** yes.
