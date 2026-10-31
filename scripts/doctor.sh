#!/usr/bin/env bash
# Studio toolchain doctor. Run on your Mac from the repo root: ./scripts/doctor.sh
# Checks the CLI tools, project config, lint and build. Studio and MCP are checked by /toolcheck.
cd "$(dirname "$0")/.." || exit 1
fail=0
ok()   { printf "  \033[32mOK\033[0m    %s\n" "$1"; }
bad()  { printf "  \033[31mFAIL\033[0m  %s\n        fix: %s\n" "$1" "$2"; fail=1; }
warn() { printf "  \033[33mWARN\033[0m  %s\n        fix: %s\n" "$1" "$2"; }
have() { command -v "$1" >/dev/null 2>&1; }

echo "== CLI tools"
have git    && ok "git $(git --version | awk '{print $3}')" || bad "git missing" "xcode-select --install"
have jq     && ok "jq (needed by hooks)"                    || bad "jq missing" "brew install jq   (or update to macOS 15+, which ships jq)"
have rokit  && ok "rokit $(rokit --version 2>/dev/null | awk '{print $2}')" || bad "rokit missing" "see docs/setup.md step 2"
for t in rojo wally stylua selene; do
  have "$t" && ok "$t $($t --version 2>/dev/null | head -1 | awk '{print $NF}')" || bad "$t missing" "rokit add (see docs/setup.md step 3), then open a new terminal"
done
have claude && ok "claude (Claude Code CLI)" || warn "claude CLI not on PATH" "only needed for 'claude mcp' setup; the desktop app works too"

echo "== Project"
[ -f default.project.json ] && ok "default.project.json" || bad "default.project.json missing" "re-clone the repo"
if have rojo; then
  rojo build default.project.json -o /tmp/studio-doctor.rbxl >/dev/null 2>&1 && ok "rojo build" || bad "rojo build failed" "run: rojo build -o /tmp/x.rbxl  and read the error"
fi
if have wally; then
  if grep -qE '^[a-zA-Z_]+ *= *"' wally.toml 2>/dev/null; then
    wally install >/dev/null 2>&1 && ok "wally install" || bad "wally install failed" "run: wally install"
  else
    ok "wally (no dependencies yet)"
  fi
fi
if have selene; then
  [ -f roblox.yml ] || selene generate-roblox-std >/dev/null 2>&1
  selene src >/dev/null 2>&1 && ok "selene src" || bad "selene reports problems" "run: selene src"
fi
have stylua && { stylua --check src >/dev/null 2>&1 && ok "stylua --check src" || warn "stylua would reformat files" "run: stylua src"; }

echo "== Studio side"
if [ -d "$HOME/Documents/Roblox/Plugins" ] && ls "$HOME/Documents/Roblox/Plugins" 2>/dev/null | grep -qi rojo; then
  ok "Rojo Studio plugin installed"
else
  warn "Rojo Studio plugin not found in ~/Documents/Roblox/Plugins" "rojo plugin install   (or install 'Rojo' from the Creator Store)"
fi
if have claude; then
  if claude mcp list 2>/dev/null | grep -qi -E 'roblox|studio'; then
    ok "a Roblox Studio MCP server is registered in Claude Code"
  else
    warn "no Roblox Studio MCP server registered" "see docs/setup.md step 6"
  fi
fi

echo
if [ $fail -eq 0 ]; then
  echo "doctor: CLI toolchain OK. Next, in Claude Code: /toolcheck  (verifies rojo serve -> Studio and the MCP test call)"
else
  echo "doctor: fix the FAIL lines above, then re-run ./scripts/doctor.sh"
fi
exit $fail
