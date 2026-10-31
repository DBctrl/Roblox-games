#!/usr/bin/env bash
# PreToolUse guard for Write/Edit/MultiEdit.
#  1. Blocks content that looks like a secret.
#  2. Enforces folder ownership when the call comes from a subagent (agent_type in hook input).
# Exit 2 = block the tool call and show stderr to the agent.
set -u
input="$(cat)"

if ! command -v jq >/dev/null 2>&1; then
  echo "guard-write: jq not installed; ownership/secret checks skipped (run scripts/doctor.sh)" >&2
  exit 0
fi

file="$(jq -r '.tool_input.file_path // empty' <<<"$input")"
agent="$(jq -r '.agent_type // empty' <<<"$input")"
content="$(jq -r '[.tool_input.content, .tool_input.new_string, (.tool_input.edits // [] | map(.new_string) | join("\n"))] | map(select(. != null)) | join("\n")' <<<"$input")"
root="${CLAUDE_PROJECT_DIR:-$(pwd)}"
rel="${file#"$root"/}"

# 1. Secrets
if grep -Eq '(_\|WARNING:-DO-NOT-SHARE-THIS|ROBLOSECURITY|sk-ant-[A-Za-z0-9_-]{10,}|ghp_[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16}|-----BEGIN [A-Z ]*PRIVATE KEY-----|discord(app)?\.com/api/webhooks/|x-api-key[\"'\'' ]*[:=][\"'\'' ]*[A-Za-z0-9+/=_-]{20,})' <<<"$content"; then
  echo "BLOCKED: this write looks like it contains a secret or key. Secrets never go in the repo (CLAUDE.md rule 3)." >&2
  exit 2
fi
case "$rel" in
  .env|.env.*|*.pem|*.key) echo "BLOCKED: secret-type file ($rel) must not be created in the repo." >&2; exit 2 ;;
esac

# 2. Ownership (only for subagents; team-lead/main thread has no agent_type)
[ -z "$agent" ] && exit 0
[ "$agent" = "team-lead" ] && exit 0
[ "$rel" = "docs/decisions.md" ] && exit 0   # everyone may append decisions

allowed=""
case "$agent" in
  project-manager)        allowed="docs/backlog.md docs/status.md" ;;
  scenarist)              allowed="docs/gdd.md" ;;
  world-programmer)       allowed="src/server/World/ src/shared/World/" ;;
  gameplay-programmer)    allowed="src/server/Gameplay/ src/shared/Gameplay/" ;;
  physics-programmer)     allowed="src/client/Effects/ src/shared/Physics/" ;;
  systems-programmer)     allowed="src/client/UI/ src/server/Data/" ;;
  integration-programmer) allowed="docs/architecture.md src/shared/Contracts/ src/server/Main.server.luau src/client/Main.client.luau default.project.json wally.toml rokit.toml selene.toml stylua.toml" ;;
  builder)                allowed="assets/ docs/asset-briefs/" ;;
  qa)                     allowed="tests/ test.project.json docs/qa/" ;;
  lawyer)                 allowed="docs/legal.md" ;;
  marketer)               allowed="docs/marketing/" ;;
  *) exit 0 ;;
esac

# Programmers work in git worktrees; strip any worktree prefix such as .claude/worktrees/<name>/
rel="$(sed -E 's#^(.*/)?\.claude/worktrees/[^/]+/##' <<<"$rel")"

for a in $allowed; do
  case "$rel" in
    "$a"|"$a"*) exit 0 ;;
  esac
done
echo "BLOCKED: $agent may not write $rel. Allowed: $allowed (plus appending to docs/decisions.md). For shared changes, add a request under 'Contract requests' in your summary so team-lead routes it to integration-programmer." >&2
exit 2
