# Project Wheel

Menu-bar app for macOS that shows every Claude Code session you have running,
local or on remote machines, and which ones are waiting for you.

## How it works

- **Hooks.** `hooks/emit.sh` is registered as a Claude Code hook on each machine.
  It appends one JSON line per event (prompt submitted, turn finished, permission
  requested, session start/end) to `~/.project-wheel/events.jsonl`.
- **Local sessions.** The app tails the local journal and reads
  `~/.claude/sessions/*.json` (undocumented registry) for liveness, pid and tmux pane.
- **Remote sessions.** For each host in `~/.project-wheel/config.json`, the app
  keeps `ssh <host> tail -F ~/.project-wheel/events.jsonl` open and reconnects on
  failure. Hosts are names from `~/.ssh/config`, so ProxyJump works.
- **Switching.** Clicking a local session selects its tmux pane and raises the
  Terminal window showing it. Remote sessions open Claude Desktop.

## Setup

```sh
python3 scripts/install-hooks.py     # on each machine (add --uninstall to remove)
echo '{"remotes":["labdesktop"]}' > ~/.project-wheel/config.json
./scripts/build-app.sh && open build/ProjectWheel.app
```

Builds with the Command Line Tools alone (no Xcode). Debug the derived state with
`build/ProjectWheel.app/Contents/MacOS/ProjectWheel --dump`.

## Roadmap

1. ~~Hooks and journal, local and remote~~
2. ~~Menu-bar list with status~~
3. Radial wheel on a global hotkey, with a reminder card per project
4. Focus mode: raise all of a project's windows, hide the rest
5. Saved window layouts per display configuration
