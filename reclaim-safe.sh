#!/usr/bin/env bash
# reclaim-safe.sh — reclaim ONLY regenerable disk. Everything here re-downloads
# or rebuilds on demand. Safe to run anytime or weekly.
#
# Three tiers, in order of caution:
#   1. Package-manager caches  — always purged (uv/npm/pip/yarn/pnpm/brew/docker)
#   2. Dormant build artifacts — node_modules and Rust target/ dirs in projects
#      untouched for ARTIFACT_AGE_DAYS+ days. Active work is never touched.
#   3. Alerting                — email via gws ONLY when free space is low or a
#      step failed. Silent on healthy runs, so an alert always means act.
#
# Born 2026-06-06. Rewritten 2026-09-04 after the disk hit 100% (3.4 GB free)
# while this job ran weekly and freed under 1 GB a run. Three consecutive runs
# logged "Now available: 40Gi / 21Gi / 15Gi" and told nobody: it was purging
# caches while 28 GB of build artifacts, a 10 GB VM image and 32 GB of image
# scratch piled up in places it never looked. See reclaim-deep.sh for those.
#
# Usage:
#   ./reclaim-safe.sh                # purge, then alert if low or failing
#   ./reclaim-safe.sh --dry-run      # preview, change nothing
#   ./reclaim-safe.sh --no-artifacts # tier 1 only (caches)
set -uo pipefail
export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
if [ -d "$HOME/.nvm/versions/node" ]; then
  for d in "$HOME"/.nvm/versions/node/*/bin; do [ -d "$d" ] && PATH="$PATH:$d"; done
fi

# ---- tunables (env-overridable) -------------------------------------------
EMAIL_TO="${RECLAIM_EMAIL_TO:-cschuman@gmail.com}"
WARN_PCT="${RECLAIM_WARN_PCT:-15}"                 # free% <= this => warn email
CRIT_PCT="${RECLAIM_CRIT_PCT:-8}"                  # free% <= this => urgent email
ARTIFACT_AGE_DAYS="${RECLAIM_ARTIFACT_AGE_DAYS:-60}"
PROJECTS_ROOT="${RECLAIM_PROJECTS_ROOT:-$HOME/Projects}"

DRY=0; ARTIFACTS=1
for a in "$@"; do
  case "$a" in
    --dry-run)      DRY=1 ;;
    --no-artifacts) ARTIFACTS=0 ;;
    -h|--help)      sed -n '2,20p' "$0"; exit 0 ;;
  esac
done

FAILURES=""
avail_kb() { df -k / | awk 'NR==2{print $4}'; }
free_pct() { df -k / | awk 'NR==2{printf "%d", ($4/$2)*100}'; }

# run: execute a step and SURFACE its error instead of swallowing it.
# The old version redirected stderr to /dev/null, which hid a pnpm failure that
# recurred silently every single week under launchd's minimal PATH.
run() {
  if [ "$DRY" = 1 ]; then echo "  [dry-run] $*"; return 0; fi
  local out
  if out=$(eval "$*" 2>&1); then
    echo "  + $*"
  else
    echo "  ! $* — FAILED"
    printf '%s\n' "$out" | tail -3 | sed 's/^/      /'
    FAILURES="${FAILURES}
  - $*: $(printf '%s' "$out" | tail -1)"
  fi
}

before=$(avail_kb)
echo "Reclaiming regenerable disk$([ "$DRY" = 1 ] && echo ' (DRY RUN)')..."

# ---- tier 1: package-manager caches ---------------------------------------
echo "[1/2] package-manager caches"
command -v uv   >/dev/null && run "uv cache clean"
command -v npm  >/dev/null && run "npm cache clean --force"
# `npm cache clean` only clears _cacache. The npx cache is a separate tree that
# grows with every `npx <pkg>` call and is never pruned — it was 2.2 GB here
# while _cacache sat at 2.5 MB. Fully regenerable: npx re-fetches on demand.
[ -d "$HOME/.npm/_npx" ] && run "rm -rf \"$HOME/.npm/_npx\""
command -v pip  >/dev/null && run "pip cache purge"
command -v pip3 >/dev/null && run "pip3 cache purge"
command -v yarn >/dev/null && run "yarn cache clean"
command -v pnpm >/dev/null && run "pnpm store prune"
command -v brew >/dev/null && run "brew cleanup -s --prune=all"
# `docker system prune -f` alone leaves unused *tagged* images and every named
# volume untouched. That was 3.1 GB still sitting there after each weekly run.
if command -v docker >/dev/null && docker info >/dev/null 2>&1; then
  run "docker image prune -af"
  run "docker volume prune -af"
  run "docker builder prune -af"
fi

# ---- tier 2: dormant build artifacts --------------------------------------
# A project counts as ACTIVE if any non-artifact file changed inside the window.
# Active projects are skipped entirely, so this never costs you a rebuild on
# something you are working on.
if [ "$ARTIFACTS" = 1 ]; then
  echo "[2/2] dormant build artifacts (untouched ${ARTIFACT_AGE_DAYS}+ days)"
  n=0; freed_mb=0
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    root="${d%/node_modules}"; root="${root%/target}"
    case "$d" in */target) [ -f "$root/Cargo.toml" ] || continue ;; esac
    # -mtime -N, not -newermt "N days ago": the latter is GNU-only syntax and is
    # rejected outright by BSD find / bfs, which silently made every project look
    # active. The artifact dirs are pruned too — node_modules is touched on every
    # install, so leaving it in the scan marks a dormant project as active.
    if find "$root" -maxdepth 2 \
         \( -name node_modules -o -name target -o -name .git \) -prune -o \
         -mtime -"${ARTIFACT_AGE_DAYS}" -print -quit 2>/dev/null | grep -q .; then
      continue
    fi
    sz=$(du -sm "$d" 2>/dev/null | cut -f1); sz="${sz:-0}"
    if [ "$DRY" = 1 ]; then
      echo "  [dry-run] rm -rf ${d#$HOME/} (${sz}MB)"
    else
      rm -rf "$d" && echo "  + removed ${sz}MB  ${d#$HOME/}"
    fi
    n=$((n+1)); freed_mb=$((freed_mb+sz))
  done < <(find "$PROJECTS_ROOT" -type d \( -name node_modules -o -name target \) -prune 2>/dev/null)
  [ "$n" -eq 0 ] && echo "  (none dormant — every project has recent activity)"
fi

after=$(avail_kb); pct=$(free_pct)
freed_gb=$(awk -v b="$before" -v a="$after" 'BEGIN{d=(a-b)/1024/1024; if(d<0)d=0; printf "%.1f",d}')

if [ "$DRY" = 1 ]; then
  echo "Dry run complete. Re-run without --dry-run to execute."
  exit 0
fi
echo "Freed ~${freed_gb} GB. Now available: $(df -h / | awk 'NR==2{print $4}') (${pct}% free)"

# ---- tier 3: alert ONLY when actionable -----------------------------------
# Deliberately no healthy-state digest: a weekly email that always arrives is a
# weekly email you stop reading, which is exactly how 40 -> 21 -> 15 GB slid by.
LEVEL=""
[ "$pct" -le "$WARN_PCT" ] && LEVEL="low"
[ "$pct" -le "$CRIT_PCT" ] && LEVEL="critical"
[ -n "$FAILURES" ] && [ -z "$LEVEL" ] && LEVEL="failure"
[ -z "$LEVEL" ] && { echo "$(date '+%F %T')  all clear (${pct}% free, freed ${freed_gb} GB)"; exit 0; }

REPORT=$(mktemp -t reclaim); trap 'rm -f "$REPORT"' EXIT
{
  echo "Disk: $(df -h / | awk 'NR==2{print $4}') free of $(df -h / | awk 'NR==2{print $2}')  (${pct}% free)"
  echo "Weekly reclaim freed ~${freed_gb} GB — not enough to keep ahead."
  [ -n "$FAILURES" ] && { echo; echo "Steps that FAILED this run:"; printf '%s\n' "$FAILURES"; }
  echo
  echo "Largest reclaimable targets right now:"
  for p in "$HOME/Library/Application Support/Claude/vm_bundles" \
           "$HOME/Library/Developer/CoreSimulator/Devices" \
           "$HOME/Library/Caches" "$HOME/.cache" "$HOME/.gradle" "$HOME/Downloads"; do
    [ -e "$p" ] && printf '  %-50s %s\n' "${p#$HOME/}" "$(du -sh "$p" 2>/dev/null | cut -f1)"
  done
  echo
  echo "Biggest build artifacts under ${PROJECTS_ROOT#$HOME/}:"
  find "$PROJECTS_ROOT" -type d \( -name node_modules -o -name target \) -prune 2>/dev/null \
    | while read -r d; do printf '%s\t%s\n' "$(du -sm "$d" 2>/dev/null | cut -f1)" "${d#$HOME/}"; done \
    | sort -rn | head -8 | awk -F'\t' '{printf "  %6d MB  %s\n", $1, $2}'
  echo
  echo "Next step: ./reclaim-deep.sh --dry-run   (VM images, simulators, stale worktrees)"
} > "$REPORT"

cat "$REPORT"
if command -v gws >/dev/null; then
  case "$LEVEL" in
    critical) subj="🚨 Disk critical — ${pct}% free" ;;
    low)      subj="⚠️ Disk low — ${pct}% free" ;;
    *)        subj="⚠️ Reclaim job had failures — ${pct}% free" ;;
  esac
  html="<pre style=\"font-family:ui-monospace,Menlo,monospace;font-size:13px\">$(sed 's/&/\&amp;/g;s/</\&lt;/g;s/>/\&gt;/g' "$REPORT")</pre>"
  gws gmail +send --to "$EMAIL_TO" --subject "$subj" --body "$html" --html >/dev/null 2>&1 \
    || gws gmail +send --to "$EMAIL_TO" --subject "$subj" --body "$(cat "$REPORT")" >/dev/null 2>&1
fi
