#!/usr/bin/env bash
# PostToolUse: format + lint any Luau file that was just written.
# Exit 2 sends the lint errors back to the agent so it fixes them.
set -u
input="$(cat)"
command -v jq >/dev/null 2>&1 || exit 0
file="$(jq -r '.tool_input.file_path // empty' <<<"$input")"
case "$file" in
  *.luau|*.lua) ;;
  *) exit 0 ;;
esac
[ -f "$file" ] || exit 0
cd "${CLAUDE_PROJECT_DIR:-.}" || exit 0

command -v stylua >/dev/null 2>&1 && stylua "$file" 2>&1 >/dev/null

if command -v selene >/dev/null 2>&1; then
  out="$(selene --display-style quiet "$file" 2>&1)"
  if echo "$out" | grep -qE '(error|warning)\['; then
    echo "Selene found problems in $file. Fix them before finishing:" >&2
    echo "$out" >&2
    exit 2
  fi
fi

if ! head -n 3 "$file" | grep -q -- '--!strict'; then
  echo "Note: $file has no --!strict header. Add it, or record why not in docs/decisions.md." >&2
  exit 2
fi
exit 0
