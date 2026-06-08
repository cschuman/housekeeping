#!/usr/bin/env bash
# Install (or reinstall) the weekly reclaim-safe launchd job for the current user.
# Idempotent: safe to re-run. Use `./install.sh uninstall` to remove it.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LABEL="com.$(id -un).housekeeping"
PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"
DOMAIN="gui/$(id -u)"

if [ "${1:-}" = "uninstall" ]; then
  launchctl bootout "${DOMAIN}/${LABEL}" 2>/dev/null || true
  rm -f "$PLIST"
  echo "Removed ${LABEL}."
  exit 0
fi

mkdir -p "$HOME/Library/LaunchAgents"
sed -e "s|__LABEL__|${LABEL}|g" \
    -e "s|__SCRIPT__|${DIR}/reclaim-safe.sh|g" \
    -e "s|__LOG__|${DIR}/reclaim.log|g" \
    "${DIR}/com.user.housekeeping.plist.template" > "$PLIST"

chmod +x "${DIR}"/*.sh
launchctl bootout "${DOMAIN}/${LABEL}" 2>/dev/null || true
launchctl bootstrap "${DOMAIN}" "$PLIST"

echo "Installed ${LABEL}"
echo "  Runs: ${DIR}/reclaim-safe.sh  weekly (Sundays 11:17)"
echo "  Log:  ${DIR}/reclaim.log"
echo "Uninstall with: ./install.sh uninstall"
