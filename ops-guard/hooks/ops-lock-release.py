#!/usr/bin/env python3
"""PostToolUse (Bash) companion to ops-guard.py: release this call's daemon locks.

Removes every <lock dir>/*.lock whose session_id matches the payload and whose
tool_use_id matches (or either side has no tool_use_id). Never prints, never
blocks: any error is swallowed. Lock dir is $OPS_LOCK_DIR or ~/.claude/locks.
"""
import fcntl, json, os, sys


def main():
    try:
        payload = json.load(sys.stdin)
    except Exception:
        return
    if not isinstance(payload, dict):
        return
    sid = str(payload.get("session_id") or "")
    tuid = str(payload.get("tool_use_id") or "")
    if not sid:
        return
    d = os.environ.get("OPS_LOCK_DIR") or os.path.expanduser("~/.claude/locks")
    if not os.path.isdir(d):
        return
    with open(os.path.join(d, ".ops-guard.mutex"), "a+") as mfh:
        fcntl.flock(mfh, fcntl.LOCK_EX)
        for name in os.listdir(d):
            if not name.endswith(".lock"):
                continue
            path = os.path.join(d, name)
            try:
                with open(path, encoding="utf-8") as fh:
                    lk = json.load(fh)
            except (OSError, ValueError):
                continue
            if not isinstance(lk, dict) or str(lk.get("session_id") or "") != sid:
                continue
            ltu = str(lk.get("tool_use_id") or "")
            if not ltu or not tuid or ltu == tuid:
                try:
                    os.unlink(path)
                except OSError:
                    pass


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass
    sys.exit(0)
