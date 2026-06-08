#!/usr/bin/env bash
# Reclaim ONLY regenerable caches. Everything here re-downloads/rebuilds on demand.
# Safe to run anytime or weekly. Reports GB freed.  Use --dry-run to preview.
set -uo pipefail
DRY=0; [ "${1:-}" = "--dry-run" ] && DRY=1

# Make PATH self-sufficient so this works under launchd (which has a minimal PATH).
export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
if [ -d "$HOME/.nvm/versions/node" ]; then
  for d in "$HOME"/.nvm/versions/node/*/bin; do [ -d "$d" ] && PATH="$PATH:$d"; done
fi

avail() { df -k / | awk 'NR==2{print $4}'; }   # KB available
run()   { if [ "$DRY" = 1 ]; then echo "  [dry-run] $*"; else echo "  + $*"; eval "$* >/dev/null 2>&1" || echo "    (skipped/failed)"; fi; }

before=$(avail)
echo "Reclaiming regenerable caches$([ "$DRY" = 1 ] && echo ' (DRY RUN)')..."

command -v uv      >/dev/null && run "uv cache clean"
command -v npm     >/dev/null && run "npm cache clean --force"
command -v pip     >/dev/null && run "pip cache purge"
command -v pip3    >/dev/null && run "pip3 cache purge"
command -v yarn    >/dev/null && run "yarn cache clean"
command -v pnpm    >/dev/null && run "pnpm store prune"
command -v brew    >/dev/null && run "brew cleanup -s"
command -v docker  >/dev/null && docker info >/dev/null 2>&1 && run "docker system prune -f"

after=$(avail)
if [ "$DRY" = 1 ]; then
  echo "Dry run complete. Re-run without --dry-run to execute."
else
  freed_gb=$(awk -v b="$before" -v a="$after" 'BEGIN{printf "%.1f",(a-b)/1024/1024}')
  echo "Freed ~${freed_gb} GB. Now available: $(df -h / | awk 'NR==2{print $4}')"
fi
