#!/bin/sh
# Project Wheel hook: append one JSON line per Claude Code hook event to a
# per-machine journal. The Mac app tails this file (locally, or over SSH for
# remote machines). Must stay fast, dependency-free and never fail the hook.
dir="${PROJECT_WHEEL_DIR:-$HOME/.project-wheel}"
mkdir -p "$dir" 2>/dev/null
# Hook stdin is a JSON object; raw newlines can only be inter-token whitespace
# (newlines inside strings are escaped), so stripping them yields one line.
payload=$(tr -d '\n\r')
[ -n "$payload" ] || exit 0
printf '{"ts":%s,"host":"%s","tmux":"%s","payload":%s}\n' \
  "$(date +%s)" "$(hostname -s 2>/dev/null || hostname)" "${TMUX_PANE:-}" "$payload" \
  >> "$dir/events.jsonl" 2>/dev/null
exit 0
