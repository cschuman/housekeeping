#!/usr/bin/env bash
# System Housekeeping Audit — READ ONLY. Sweeps Time / Space / Energy / Entropy.
# Changes nothing. See FRAMEWORK.md. Re-run anytime: ./audit.sh
set -uo pipefail

bold() { printf '\033[1m%s\033[0m\n' "$1"; }
hdr()  { printf '\n\033[1;36m== %s ==\033[0m\n' "$1"; }
sub()  { printf '\033[33m• %s\033[0m\n' "$1"; }
sz()   { du -sh "$1" 2>/dev/null | cut -f1; }   # size of a path, blank if missing

bold "System Housekeeping Audit — $(date '+%Y-%m-%d %H:%M')"

hdr "Disk pressure"
df -h / | sed -n '1,2p'

hdr "SPACE — reclaimable caches & artifacts"
for p in ~/.cache/uv ~/.npm ~/.cache/huggingface ~/.cache/pip ~/Library/Caches/Homebrew \
         ~/Library/Caches/ms-playwright ~/Library/Caches/Yarn ~/.cache; do
  [ -e "$p" ] && printf '  %-40s %s\n' "$p" "$(sz "$p")"
done
sub "Homebrew reclaimable (dry run):"; brew cleanup -n 2>/dev/null | tail -1
command -v docker >/dev/null && { sub "Docker:"; docker system df 2>/dev/null | sed 's/^/    /'; }
# No -maxdepth: the worst offenders hide deep. The old -maxdepth 4 missed
# .claude/worktrees/<wt>/app/node_modules at depth 6 entirely, so this lens
# under-reported build sprawl by more than half while the disk filled up.
sub "Build artifacts under ~/Projects (node_modules + Rust target):"
find ~/Projects -type d \( -name node_modules -o -name target \) -prune 2>/dev/null \
  | while read -r d; do
      case "$d" in */target) [ -f "${d%/target}/Cargo.toml" ] || continue ;; esac
      printf '%s\t%s\n' "$(du -sm "$d" 2>/dev/null | cut -f1)" "$d"
    done | sort -rn > /tmp/.hk_artifacts.$$
head -6 /tmp/.hk_artifacts.$$ | awk '{printf "    %5sM  %s\n",$1,$2}'
awk -F'\t' '{s+=$1; n++} END{printf "    ---- %d dirs totalling %.1f GB\n", n, s/1024}' /tmp/.hk_artifacts.$$
rm -f /tmp/.hk_artifacts.$$

sub "Heavyweight regenerables (see reclaim-deep.sh):"
for p in ~/"Library/Application Support/Claude/vm_bundles" \
         ~/Library/Developer/CoreSimulator/Devices \
         ~/.gradle ~/.bun ~/.expo; do
  [ -e "$p" ] && printf '    %-46s %s\n' "$(basename "$p")" "$(sz "$p")"
done
sub "Self-updater caches (ShipIt/Sparkle):"
find ~/Library/Caches -maxdepth 1 -type d -name "*.ShipIt" 2>/dev/null \
  | while read -r d; do printf '    %-46s %s\n' "$(basename "$d")" "$(sz "$d")"; done
sub "Stale .claude worktrees:"
find ~/Projects -type d -path "*/.claude/worktrees/*" -mindepth 3 -maxdepth 6 2>/dev/null \
  | while read -r wt; do
      [ -e "$wt/.git" ] || continue
      d=$(git -C "$wt" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
      u=$(git -C "$wt" log HEAD --not --remotes --oneline 2>/dev/null | wc -l | tr -d ' ')
      [ "${d:-0}" -eq 0 ] && [ "${u:-0}" -eq 0 ] && printf '    %-8s %s (clean)\n' "$(sz "$wt")" "$(basename "$wt")"
    done | head -8
sub "nvm node versions (old ones reclaimable):"; ls ~/.nvm/versions/node 2>/dev/null | sed 's/^/    /'
sub "Downloads / Desktop / Trash:"
for p in ~/Downloads ~/Desktop ~/.Trash; do printf '    %-12s %s\n' "$(basename "$p")" "$(sz "$p")"; done
sub "Stray installers in Downloads:"; ls -1 ~/Downloads/*.dmg ~/Downloads/*.pkg 2>/dev/null | sed 's/^/    /' || echo "    none"

hdr "TIME — shell / CLI latency"
sub "Interactive zsh startup (3x):"
for i in 1 2 3; do { /usr/bin/time zsh -i -c exit; } 2>&1 | awk '/real/{printf "    %ss\n",$1}'; done
sub "Duplicate \$PATH entries:"; echo "$PATH" | tr ':' '\n' | sort | uniq -d | sed 's/^/    /' || true
sub "Stale .zcompdump files:"; ls -1 ~/.zcompdump* 2>/dev/null | sed 's/^/    /' || echo "    none"

hdr "ENERGY — background load"
sub "Top CPU:"; ps -arcwwwxo '%cpu,%mem,comm' 2>/dev/null | head -8 | sed 's/^/    /'
sub "Top MEM:"; ps -amcwwwxo '%cpu,%mem,comm' 2>/dev/null | head -8 | sed 's/^/    /'
sub "Third-party login agents:"; ls -1 ~/Library/LaunchAgents/ 2>/dev/null | grep -v '^com.apple' | sed 's/^/    /'
sub "Failed launchd jobs (nonzero status):"
launchctl list 2>/dev/null | awk 'NR>1 && $2!=0 && $2!="-" {print "    "$3" (status "$2")"}' | grep -v com.apple | head -10

hdr "ENTROPY — staleness & cruft"
sub "Homebrew doctor (head):"; brew doctor 2>&1 | grep -iE 'warning|deprecat|outdated|newer' | head -6 | sed 's/^/    /'
sub "Outdated brew formulae:"; echo "    $(brew outdated 2>/dev/null | wc -l | tr -d ' ') formulae"
sub "Outdated global npm:"; npm -g outdated 2>/dev/null | tail -n +2 | sed 's/^/    /' | head -10
sub ".DS_Store under ~/Projects:"; echo "    $(find ~/Projects -name .DS_Store 2>/dev/null | wc -l | tr -d ' ') files"
sub "Broken symlinks in bin dirs:"
find /opt/homebrew/bin ~/.local/bin /usr/local/bin -maxdepth 1 -type l ! -exec test -e {} \; -print 2>/dev/null | sed 's/^/    /' || echo "    none"
sub "Old SSH artifacts (>1yr):"; find ~/.ssh -maxdepth 1 -type f -mtime +365 2>/dev/null | sed 's/^/    /' || true

printf '\n\033[1;32mDone. Triage: Impact ÷ Effort. Reversible cache wins → run ./reclaim-safe.sh\033[0m\n'
