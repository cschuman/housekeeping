#!/usr/bin/env bash
# install.sh: install ops-guard. NOT run by the build; Corey runs it after reviewing settings.diff.
# Idempotent: re-running changes nothing that is already in place. Prints every action.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
CL="$HOME/.claude"
SETTINGS="$CL/settings.json"
STAMP="$(date +%Y%m%d)"

say() { printf 'install: %s\n' "$*"; }
sha() { shasum -a 256 "$1" | awk '{print $1}'; }

# ---- gates: tests pass, files compile, proposal is not stale --------------
python3 -m py_compile "$HERE/hooks/ops-guard.py" "$HERE/hooks/ops-lock-release.py"
python3 "$HERE/hooks/ops-guard.test.py" >/dev/null 2>&1 || { say "tests FAILED; nothing installed"; exit 1; }
python3 -c 'import json,sys;json.load(open(sys.argv[1]))' "$HERE/settings.proposed.json"
cur="$(sha "$SETTINGS")"
base="$(tr -d '[:space:]' < "$HERE/settings.base.sha256")"
prop="$(sha "$HERE/settings.proposed.json")"
if [ "$cur" != "$base" ] && [ "$cur" != "$prop" ]; then
  say "settings.json changed since the proposal was built; run ./build-settings.py, review settings.diff, retry"
  exit 1
fi

# ---- hooks ---------------------------------------------------------------
mkdir -p "$CL/hooks"
for f in ops-guard.py ops-lock-release.py; do
  if cmp -s "$HERE/hooks/$f" "$CL/hooks/$f"; then say "hooks/$f already current"
  else install -m 755 "$HERE/hooks/$f" "$CL/hooks/$f"; say "installed $CL/hooks/$f"; fi
done

# ---- known recipients (never clobber manual edits) -----------------------
if [ ! -e "$CL/known-recipients.txt" ]; then
  install -m 600 "$HERE/known-recipients.txt" "$CL/known-recipients.txt"; say "installed $CL/known-recipients.txt"
elif cmp -s "$HERE/known-recipients.txt" "$CL/known-recipients.txt"; then
  say "known-recipients.txt already current"
else
  say "known-recipients.txt differs from the staged copy; left as is (diff them by hand)"
fi

# ---- lock dir ------------------------------------------------------------
if [ -d "$CL/locks" ]; then say "$CL/locks exists"; else mkdir -p "$CL/locks"; say "created $CL/locks"; fi
chmod 700 "$CL/locks"

# ---- healthcheck ---------------------------------------------------------
HC="$HERE/../healthcheck.sh"
if cmp -s "$HERE/healthcheck.sh" "$HC"; then say "healthcheck.sh already current"
else install -m 755 "$HERE/healthcheck.sh" "$HC"; say "installed $(cd "$HERE/.." && pwd)/healthcheck.sh"; fi

# ---- settings (last, so the hooks it names already exist) ----------------
if [ "$cur" = "$prop" ]; then
  say "settings.json already matches settings.proposed.json"
else
  bak="$SETTINGS.bak-$STAMP"
  [ -e "$bak" ] && bak="$SETTINGS.bak-$STAMP-$(date +%H%M%S)"
  cp -p "$SETTINGS" "$bak"; say "backed up settings.json to $bak"
  cp "$HERE/settings.proposed.json" "$SETTINGS"; say "wrote settings.proposed.json over $SETTINGS"
fi
say "done. Run ~/Projects/housekeeping/healthcheck.sh to verify."
