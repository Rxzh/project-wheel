#!/usr/bin/env python3
"""Install (or remove with --uninstall) the Project Wheel hooks in
~/.claude/settings.json. Idempotent; keeps any other hooks; writes a backup.

Usage: install-hooks.py [--uninstall]
The hook script is copied to ~/.project-wheel/emit.sh so the settings entry
does not depend on where this repo lives.
"""
import json, os, shutil, sys, time

EVENTS = [
    "SessionStart", "SessionEnd", "UserPromptSubmit", "Stop", "StopFailure",
    "PermissionRequest", "Notification", "PostToolUse",
]
HOME = os.path.expanduser("~")
WHEEL_DIR = os.path.join(HOME, ".project-wheel")
HOOK_DST = os.path.join(WHEEL_DIR, "emit.sh")
COMMAND = '"$HOME/.project-wheel/emit.sh"'
SETTINGS = os.path.join(os.environ.get("CLAUDE_CONFIG_DIR", os.path.join(HOME, ".claude")), "settings.json")


def is_ours(group):
    return any("project-wheel/emit.sh" in h.get("command", "") for h in group.get("hooks", []))


def main():
    uninstall = "--uninstall" in sys.argv
    settings = {}
    if os.path.exists(SETTINGS):
        with open(SETTINGS) as f:
            settings = json.load(f)
        shutil.copy2(SETTINGS, SETTINGS + ".project-wheel-backup-%d" % time.time())

    hooks = settings.get("hooks", {})
    for event in list(hooks):
        hooks[event] = [g for g in hooks[event] if not is_ours(g)]
        if not hooks[event]:
            del hooks[event]

    if not uninstall:
        os.makedirs(WHEEL_DIR, exist_ok=True)
        src = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "hooks", "emit.sh")
        if os.path.exists(src):
            shutil.copy2(src, HOOK_DST)
        os.chmod(HOOK_DST, 0o755)
        events = [e for e in EVENTS if e not in os.environ.get("PW_SKIP_EVENTS", "").split(",")]
        for event in events:
            hooks.setdefault(event, []).append(
                {"hooks": [{"type": "command", "command": COMMAND, "timeout": 5}]}
            )

    if hooks:
        settings["hooks"] = hooks
    else:
        settings.pop("hooks", None)

    tmp = SETTINGS + ".tmp"
    with open(tmp, "w") as f:
        json.dump(settings, f, indent=2, ensure_ascii=False)
        f.write("\n")
    os.replace(tmp, SETTINGS)
    print(("removed from " if uninstall else "installed in ") + SETTINGS)


if __name__ == "__main__":
    main()
