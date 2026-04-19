#!/bin/bash
# Hook / shell-wrapper entry point for Agent Notifier.
# Ships inside the app bundle at: Contents/Resources/notify.sh
#
# Usage: notify.sh [default_message] [sound_name] [title_prefix] [actionable]
#   default_message : fallback body if stdin has no .message / .tool_name
#   sound_name      : macOS sound name (Glass | Pop | ...)
#   title_prefix    : "Claude Code", "Codex", etc.
#   actionable      : "1" force on, "0" force off, "" auto-detect from stdin

set -u

default_msg="${1:-Needs your confirmation}"
sound_name="${2:-Glass}"
title_prefix="${3:-Claude Code}"
actionable="${4:-}"

input=$(cat)

msg=$(echo "$input" | jq -r --arg default "$default_msg" '
  if .message then .message
  elif .tool_name == "Bash" then "Run: " + (.tool_input.command // "Bash command")
  elif .tool_name then "Tool: " + .tool_name
  else $default
  end
')

if [ "${#msg}" -gt 140 ]; then
  msg="${msg:0:137}..."
fi

detect_app() {
  local pid="$PPID"
  local hops=0
  while [ -n "$pid" ] && [ "$pid" != "1" ] && [ "$hops" -lt 25 ]; do
    local name
    name=$(ps -o comm= -p "$pid" 2>/dev/null | awk -F/ '{print $NF}')
    case "$name" in
      Cursor|Cursor\ Helper*)          echo "Cursor|com.todesktop.230313mzl4w4u92"; return ;;
      iTerm2|iTermServer*)             echo "iTerm|com.googlecode.iterm2"; return ;;
      ghostty|Ghostty)                 echo "Ghostty|com.mitchellh.ghostty"; return ;;
      Terminal)                        echo "Terminal|com.apple.Terminal"; return ;;
      Code|Code\ Helper*)              echo "VS Code|com.microsoft.VSCode"; return ;;
      "Visual Studio Code"|"Visual Studio Code Helper"*) echo "VS Code|com.microsoft.VSCode"; return ;;
    esac
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    hops=$((hops + 1))
  done
  echo "|"
}

IFS='|' read -r app_name bundle_id < <(detect_app)

now=$(date "+%H:%M:%S")
title="$title_prefix"
if [ -n "$app_name" ]; then
  title="$title_prefix · $app_name"
fi
subtitle="$now"

APP_BUNDLE=$(cd "$(dirname "$0")/../.." && pwd)

actionable_pid=""
case "$actionable" in
    1)
        actionable_pid="$PPID" ;;
    0)
        actionable_pid="" ;;
    *)
        if echo "$input" | jq -e '.tool_name != null' >/dev/null 2>&1; then
            actionable_pid="$PPID"
        fi
        ;;
esac

open -n -a "$APP_BUNDLE" --args \
  "$title" "$subtitle" "$msg" "$sound_name" "$bundle_id" "$actionable_pid" >/dev/null 2>&1 || true
