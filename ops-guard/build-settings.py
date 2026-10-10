#!/usr/bin/env python3
"""Build settings.proposed.json = ~/.claude/settings.json + ops-guard additions.

Read-only on ~/.claude/settings.json. Keeps every existing key and its order,
appends only entries that are not already present, never touches
permissions.deny or defaultMode. Also writes settings.base.sha256 (hash of the
file the proposal was built from) so install.sh can refuse a stale proposal.
"""
import hashlib, json, os

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.expanduser("~/.claude/settings.json")
HOOKS = "/Users/corey/.claude/hooks"

ALLOW = """Bash(fly status:*) Bash(fly releases:*) Bash(fly apps list:*) Bash(fly secrets list:*) Bash(fly machine list:*)
Bash(fly checks list:*) Bash(fly auth whoami:*) Bash(gws auth status:*) Bash(gws gmail users getProfile:*)
Bash(gws gmail users messages list:*) Bash(gws gmail users messages get:*) Bash(gws gmail users threads get:*)
Bash(gws gmail users threads list:*) Bash(gws sheets spreadsheets get:*) Bash(gws sheets spreadsheets values get:*)
Bash(gws calendar events list:*) Bash(tailscale status:*) Bash(tailscale ping:*) Bash(tailscale ip:*)
Bash(crontab -l) Bash(launchctl list:*) Bash(launchctl print:*) Bash(pgrep:*)
Bash(/Users/corey/Projects/housekeeping/healthcheck.sh:*) Bash(~/Projects/housekeeping/healthcheck.sh:*)"""
ASK = ["Bash(fly secrets set:*)", "Bash(fly secrets unset:*)", "Bash(fly secrets import:*)",
       "Bash(fly postgres connect:*)", "Bash(psql:*)"]


def split_rules(s):
    out, cur, depth = [], "", 0
    for ch in s:
        if ch.isspace() and depth == 0:
            if cur:
                out.append(cur)
            cur = ""
            continue
        depth += ch == "("
        depth -= ch == ")"
        cur += ch
    if cur:
        out.append(cur)
    return out


def add(lst, items):
    for it in items:
        if it not in lst:
            lst.append(it)


def add_hook(entries, matcher, command, timeout):
    for e in entries:
        if e.get("matcher") == matcher and any(h.get("command") == command for h in e.get("hooks", [])):
            return
    entries.append({"matcher": matcher, "hooks": [{"type": "command", "command": command, "timeout": timeout}]})


def main():
    raw = open(SRC, "rb").read()
    s = json.loads(raw)
    perms = s.setdefault("permissions", {})
    add(perms.setdefault("allow", []), split_rules(ALLOW))
    add(perms.setdefault("ask", []), ASK)
    hooks = s.setdefault("hooks", {})
    pre = hooks.setdefault("PreToolUse", [])
    add_hook(pre, "Bash", f"{HOOKS}/ops-guard.py", 10)
    add_hook(pre, "mcp__Neon__.*", f"{HOOKS}/ops-guard.py", 10)
    for ev in ("PostToolUse", "PostToolUseFailure"):  # release on success and on failure
        add_hook(hooks.setdefault(ev, []), "Bash", f"{HOOKS}/ops-lock-release.py", 5)
    with open(os.path.join(HERE, "settings.proposed.json"), "w") as fh:
        json.dump(s, fh, indent=2, ensure_ascii=False)
        fh.write("\n")
    with open(os.path.join(HERE, "settings.base.sha256"), "w") as fh:
        fh.write(hashlib.sha256(raw).hexdigest() + "\n")
    print("wrote settings.proposed.json and settings.base.sha256")


if __name__ == "__main__":
    main()
