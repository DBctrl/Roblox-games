# Setup on your Mac (one time, about 15 minutes)

You already have Roblox Studio and Claude Code. Missing: Git, a toolchain manager (Rokit), Rojo,
Wally, StyLua, Selene, jq, the Rojo Studio plugin, and the Studio MCP connection.

## 1. Git and Apple developer tools
```bash
xcode-select --install        # installs git; skip if `git --version` already works
```

## 2. Rokit (installs Roblox CLI tools per project)
```bash
curl -sSf https://raw.githubusercontent.com/rojo-rbx/rokit/main/scripts/install.sh | bash
# then close and reopen Terminal
rokit --version
```

## 3. Rojo, Wally, StyLua, Selene (pinned in this repo's rokit.toml)
From the repo folder:
```bash
rokit add rojo-rbx/rojo
rokit add UpliftGames/wally
rokit add JohnnyMorganz/StyLua
rokit add Kampfkarren/selene
rokit install
```
Commit the updated `rokit.toml` so the versions stay pinned.

## 4. jq (the hooks use it)
```bash
jq --version || brew install jq    # macOS 15+ already includes jq
```

## 5. Rojo Studio plugin
```bash
rojo plugin install
```
Restart Studio. The **Rojo** button appears under the **Plugins** tab.

## 6. Roblox Studio MCP server (lets agents inspect and edit the open place and run playtests)
Roblox now builds an MCP server into Studio, and the older standalone `studio-rust-mcp-server`
was archived in April 2026.
1. Update Roblox Studio to the latest version.
2. In Studio, open the Assistant / MCP settings and turn on the built-in **MCP server**. Use
   **Quick Connect** and pick **Claude Code**. Studio shows a manual command if Quick Connect fails.
   Menu names change between Studio versions. Roblox's page is
   https://create.roblox.com/docs/studio/mcp
3. Check it in Terminal: `claude mcp list` should show the Studio server as connected.

Fallback (only if the built-in server isn't available to you): download the archived server for
macOS from https://github.com/Roblox/studio-rust-mcp-server/releases (macOS zip), run the
installer, then:
```bash
claude mcp add --transport stdio Roblox_Studio -- '/Applications/RobloxStudioMCP.app/Contents/MacOS/rbx-studio-mcp' --stdio
```

## 7. Verify
```bash
./scripts/doctor.sh       # all OK?
rojo serve                # leave running
```
In Studio, open a Baseplate, then **Plugins**, then **Rojo**, then **Connect**. `ServerScriptService > Server` should appear.
Then in Claude Code (in this folder) run **`/toolcheck`**. It makes a real Studio MCP test call.

## Daily use
1. Open Studio with the game place, then `rojo serve`, then Rojo, then Connect.
2. `claude` in this folder (it starts as team-lead), then `/status`, `/sprint` and so on.
3. After builder edits the map: in Studio, **File > Save to Roblox**.
