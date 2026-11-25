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
  keeps one SSH connection open that streams the remote journal and, every few
  seconds, a snapshot of the remote session registry. It reconnects on failure.
  Hosts are names from `~/.ssh/config`, so ProxyJump works. The remote login
  shell must be bash (on Windows: OpenSSH Server with Git Bash as DefaultShell;
  the hook works without `jq` there).
- **Switching.** Clicking a local session selects its tmux pane and raises the
  Terminal window showing it. Remote sessions open Claude Desktop, on the
  session itself when it has a remote-control id.

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
3. ~~Radial wheel on ⌃⌥Space (hold, aim, release; quick tap keeps it open), reminder card in the centre~~
4. Focus mode: raise all of a project's windows, hide the rest
5. Saved window layouts per display configuration
