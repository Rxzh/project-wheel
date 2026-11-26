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
- **Attached windows.** ⌃⌥A captures the frontmost window and opens the wheel in
  attach mode: the centre names the window (app, title, current project) and
  choosing a sector attaches it to that project (choosing its current project
  detaches it). A window belongs to one project at most. Attachments live in
  `~/.project-wheel/windows.json`, keyed on `local:` or `remote:` plus the
  session's directory, and disappear once the window or its app is gone.
- **Focus mode.** On a switch (wheel or menu), the app hides every app that has
  no window attached to the project (except Terminal for a local session, Claude
  for a remote one), raises the attached windows, then brings the session
  forward so it ends on top. Toggle it with « Mode focus » in the menu (on by
  default). This needs the Accessibility permission, asked for on the first ⌃⌥A;
  without it switching works as before. Release builds keep the same signature, so
  the permission survives updates; a local build is ad-hoc signed unless a
  "ProjectWheel Local Signing" certificate is in the keychain, and then each
  rebuild may require granting the permission again.

- **Free projects and names.** "Nouveau projet" in the menu creates a project
  with no session behind it: only attached windows. Any project can be renamed
  (pencil on hover, or right-click); free projects can be deleted, which detaches
  their windows. Stored in `~/.project-wheel/projects.json`.

- **Layouts.** Right-click a project, "Enregistrer la disposition des fenêtres":
  the position and size of its session window and attached windows are stored
  per display configuration (`~/.project-wheel/layouts.json`) and restored on
  each switch.
- **Background work.** A session whose turn ended while background tasks are
  still running shows "Tourne en fond", not "À toi".
- **Diagnostics.** `~/.project-wheel/app.log` records attachments, raises and layouts.

## Install

Requires macOS 14 or later (Apple Silicon or Intel).

1. Download `ProjectWheel-<version>.zip` from the
   [latest release](https://github.com/Rxzh/project-wheel/releases/latest) and unzip it.
2. Move `ProjectWheel.app` to `/Applications`. The app is not notarized, so clear
   the quarantine flag before the first launch:
   `xattr -dr com.apple.quarantine /Applications/ProjectWheel.app`
3. Install the hooks on each machine running Claude Code, from the unzipped folder:
   `python3 scripts/install-hooks.py`
4. Optionally list remote hosts (see below), then open the app.

## Build from source

```sh
python3 scripts/install-hooks.py     # on each machine (add --uninstall to remove)
echo '{"remotes":["myserver"]}' > ~/.project-wheel/config.json
./scripts/build-app.sh && open build/ProjectWheel.app
```

Builds with the Command Line Tools alone (no Xcode); `--universal` builds for
both Apple Silicon and Intel. Debug the derived state with
`build/ProjectWheel.app/Contents/MacOS/ProjectWheel --dump`.

## Roadmap

1. ~~Hooks and journal, local and remote~~
2. ~~Menu-bar list with status~~
3. ~~Radial wheel on ⌃⌥Space (hold, aim, release; quick tap keeps it open), reminder card in the centre~~
4. ~~Focus mode: windows attached by hand (⌃⌥A), raised on a switch, the rest hidden~~
5. ~~Saved window layouts per display configuration~~

## License

MIT, see [LICENSE](LICENSE).
