---
description: Verify the toolchain - rokit tools, lint/build, rojo serve to Studio, and a Studio MCP test call. Run once per machine and after updates.
---
You are team-lead. Verify the toolchain. Don't spawn agents; do it yourself.

1. Run `./scripts/doctor.sh` and show the owner any FAIL lines with their fix.
2. Ask the owner to: open Roblox Studio with a Baseplate (or the game place), run `rojo serve` in
   a terminal in this folder, then in Studio click Plugins, then Rojo, then **Connect**.
3. Studio MCP test: find the Roblox Studio MCP server's tools (from `claude mcp list` /
   your tool list). Call its code-running tool to execute:
   `print("studio-mcp-ok", game:GetService("ServerScriptService"):FindFirstChild("Server") ~= nil)`
   then read the console output (with the console tool if it's a separate tool).
   - `studio-mcp-ok true`: MCP works AND Rojo synced `src/server` into Studio.
   - `studio-mcp-ok false`: MCP works, but Rojo is not connected. Repeat step 2.
   - There are no Studio MCP tools, or the call fails: point the owner to `docs/setup.md` step 6.
4. If all pass, set the line `Toolchain: verified <date>` at the top of `docs/status.md` yourself
   (the one exception to file ownership, for this line only) and append a decision entry.
   Tell the owner they can run `/new-game <idea>`.
