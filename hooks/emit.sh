#!/bin/sh
# Project Wheel hook: append one slim JSON line per Claude Code hook event to a
# per-machine journal. The Mac app tails this file (locally, or over SSH for
# remote machines). Must stay fast and never fail the hook.
#
# Only the fields the app needs are kept, with long strings truncated: tool
# inputs and outputs never reach the journal, and the file is private (0600).
umask 077
dir="${PROJECT_WHEEL_DIR:-$HOME/.project-wheel}"
journal="$dir/events.jsonl"
mkdir -p "$dir" 2>/dev/null
ts=$(date +%s)
host=$(hostname -s 2>/dev/null || hostname)

if command -v jq >/dev/null 2>&1; then
  jq -c --argjson ts "$ts" --arg host "$host" --arg tmux "${TMUX_PANE:-}" '
    def clip: if type == "string" then .[0:500] else null end;
    {ts: $ts, host: $host, tmux: $tmux,
     payload: ({hook_event_name, session_id, cwd, source, reason,
                notification_type, tool_name, session_title,
                prompt: (.prompt | clip),
                last_assistant_message: (.last_assistant_message | clip),
                bg: ((.background_tasks // []) | length)}
               | with_entries(select(.value != null)))}' >> "$journal" 2>/dev/null
else
  # No jq: keep identifiers only (extracted textually), never the content.
  raw=$(tr -d '\n\r')
  field() { printf '%s' "$raw" | sed -n "s/.*\"$1\" *: *\"\([^\"]*\)\".*/\1/p"; }
  printf '{"ts":%s,"host":"%s","tmux":"%s","payload":{"hook_event_name":"%s","session_id":"%s","cwd":"%s","notification_type":"%s","source":"%s"}}\n' \
    "$ts" "$host" "${TMUX_PANE:-}" "$(field hook_event_name)" "$(field session_id)" \
    "$(field cwd)" "$(field notification_type)" "$(field source)" >> "$journal" 2>/dev/null
fi

# Keep the journal bounded: past ~2 MB, keep the most recent 4000 lines.
size=$(wc -c < "$journal" 2>/dev/null || echo 0)
if [ "$size" -gt 2000000 ]; then
  tail -n 4000 "$journal" > "$journal.tmp" 2>/dev/null && cat "$journal.tmp" > "$journal"
  rm -f "$journal.tmp"
fi
exit 0
