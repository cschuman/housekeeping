#!/usr/bin/env bash
# Install (or reinstall) the nightly Claude usage sentinel launchd job.
# Idempotent: safe to re-run. Use `./sentinel-install.sh uninstall` to remove it.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LABEL="com.$(id -un).usage-sentinel"
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
    -e "s|__SCRIPT__|${DIR}/usage-sentinel.sh|g" \
    -e "s|__LOG__|${DIR}/usage-sentinel.log|g" \
    "${DIR}/com.user.usage-sentinel.plist.template" > "$PLIST"

chmod +x "${DIR}/usage-sentinel.sh"
launchctl bootout "${DOMAIN}/${LABEL}" 2>/dev/null || true
launchctl bootstrap "${DOMAIN}" "$PLIST"

echo "Installed ${LABEL}"
echo "  Runs: ${DIR}/usage-sentinel.sh  daily at 22:00 (silent unless triggered)"
echo "  Log:  ${DIR}/usage-sentinel.log"
echo "  Test: ${DIR}/usage-sentinel.sh --show"
echo "Uninstall with: ./sentinel-install.sh uninstall"
