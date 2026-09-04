#!/usr/bin/env bash
# reclaim-deep.sh — the heavy, judgment-call reclaim. MANUAL ONLY, never on a timer.
#
# reclaim-safe.sh handles what is safe to delete unattended every week. This
# handles what is large but wants a human in the loop: multi-GB VM images,
# simulator devices, app updater caches, and stale git worktrees. Everything
# here still regenerates, but the cost of regenerating is minutes, not seconds,
# so you decide when to pay it.
#
# Sections (skip any with --no-<name>):
#   vm          Claude Code sandbox VM image (~10 GB) — refuses while it is in use
#   sims        iOS simulator devices + caches
#   updaters    Sparkle/ShipIt updater caches, Playwright browsers, SwiftPM, dotslash
#   worktrees   Stale .claude worktrees — REPORT ONLY unless --remove-worktrees
#
# Born 2026-09-04, from the cleanup that took the disk from 3.4 GB to 95 GB free.
#
# Usage:
#   ./reclaim-deep.sh --dry-run            # preview everything (start here)
#   ./reclaim-deep.sh                      # reclaim; worktrees reported, not touched
#   ./reclaim-deep.sh --remove-worktrees   # also remove provably-clean worktrees
set -uo pipefail
export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

PROJECTS_ROOT="${RECLAIM_PROJECTS_ROOT:-$HOME/Projects}"
DRY=0; RM_WT=0; DO_VM=1; DO_SIMS=1; DO_UPD=1; DO_WT=1
for a in "$@"; do
  case "$a" in
    --dry-run)          DRY=1 ;;
    --remove-worktrees) RM_WT=1 ;;
    --no-vm)            DO_VM=0 ;;
    --no-sims)          DO_SIMS=0 ;;
    --no-updaters)      DO_UPD=0 ;;
    --no-worktrees)     DO_WT=0 ;;
    -h|--help)          sed -n '2,24p' "$0"; exit 0 ;;
  esac
done

hdr() { printf '\n\033[1;36m== %s ==\033[0m\n' "$1"; }
sz()  { du -sh "$1" 2>/dev/null | cut -f1; }
avail_kb() { df -k / | awk 'NR==2{print $4}'; }
before=$(avail_kb)
[ "$DRY" = 1 ] && echo "DRY RUN — nothing will be deleted."

# nuke: delete a path, honouring --dry-run, reporting its size first.
nuke() {
  local p="$1" s
  [ -e "$p" ] || return 0
  s=$(sz "$p")
  if [ "$DRY" = 1 ]; then echo "  [dry-run] rm -rf ${p#$HOME/}  ($s)"
  else rm -rf "$p" 2>/dev/null; echo "  + removed $s  ${p#$HOME/}"; fi
}

# ---- VM image -------------------------------------------------------------
if [ "$DO_VM" = 1 ]; then
  hdr "Claude sandbox VM image"
  VM="$HOME/Library/Application Support/Claude/vm_bundles/claudevm.bundle"
  if [ ! -e "$VM" ]; then
    echo "  (absent — nothing to reclaim)"
  elif [ "$(lsof "$VM/rootfs.img" 2>/dev/null | wc -l | tr -d ' ')" -gt 0 ]; then
    # Deleting a disk image out from under a live VM corrupts the session.
    echo "  ! rootfs.img is OPEN by a running VM — refusing. Quit the sandbox and re-run."
  else
    nuke "$VM"
  fi
fi

# ---- iOS simulators -------------------------------------------------------
if [ "$DO_SIMS" = 1 ]; then
  hdr "iOS simulator devices"
  SIMD="$HOME/Library/Developer/CoreSimulator/Devices"
  if [ ! -d "$SIMD" ] || [ -z "$(ls -A "$SIMD" 2>/dev/null)" ]; then
    echo "  (no simulator devices)"
  elif [ "$DRY" = 1 ]; then
    echo "  [dry-run] delete $(find "$SIMD" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l | tr -d ' ') devices  ($(sz "$SIMD"))"
  else
    # Prefer simctl so CoreSimulator's own bookkeeping stays consistent. It can
    # wedge hard (a hung `simctl list` survives a service bounce), so fall back
    # to removing the device dirs — CoreSimulator prunes stale plist entries.
    if xcrun simctl delete unavailable >/dev/null 2>&1 && xcrun simctl delete all >/dev/null 2>&1; then
      echo "  + simctl deleted all devices"
    else
      echo "  ! simctl unresponsive — removing device directories directly"
      rm -rf "${SIMD:?}"/*/ 2>/dev/null
      echo "  + removed device directories"
    fi
    nuke "$HOME/Library/Developer/CoreSimulator/Caches"
  fi
fi

# ---- updater / tooling caches --------------------------------------------
if [ "$DO_UPD" = 1 ]; then
  hdr "Updater & tooling caches"
  for c in ms-playwright org.swift.swiftpm dotslash node-gyp go-build \
           kimi-desktop-updater; do
    nuke "$HOME/Library/Caches/$c"
  done
  # Every self-updating app leaves a Sparkle/ShipIt cache. Matched by glob rather
  # than named individually so new apps are covered without editing this list.
  while IFS= read -r d; do nuke "$d"; done < <(
    find "$HOME/Library/Caches" -maxdepth 1 -type d -name "*.ShipIt" 2>/dev/null)
  nuke "$HOME/.gradle/caches"; nuke "$HOME/.gradle/daemon"
  nuke "$HOME/.bun/install/cache"; nuke "$HOME/.expo/cache"
fi

# ---- stale Claude worktrees ----------------------------------------------
if [ "$DO_WT" = 1 ]; then
  hdr "Stale .claude worktrees"
  [ "$RM_WT" = 1 ] || echo "  (report only — pass --remove-worktrees to remove the clean ones)"
  clean=0; kept=0
  while IFS= read -r wt; do
    [ -n "$wt" ] && [ -e "$wt/.git" ] || continue
    dirty=$(git -C "$wt" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
    # HEAD, not --branches: `git log --branches --not --remotes` counts every
    # unpushed commit in the SHARED repo, so one busy branch falsely marks every
    # sibling worktree as unsafe. HEAD scopes it to this worktree alone.
    unpushed=$(git -C "$wt" log HEAD --not --remotes --oneline 2>/dev/null | wc -l | tr -d ' ')
    if [ "${dirty:-0}" -gt 0 ] || [ "${unpushed:-0}" -gt 0 ]; then
      printf '  KEEP  %6s  %-58s [uncommitted:%s unpushed:%s]\n' \
        "$(sz "$wt")" "${wt#$PROJECTS_ROOT/}" "$dirty" "$unpushed"
      kept=$((kept+1)); continue
    fi
    clean=$((clean+1))
    if [ "$RM_WT" != 1 ] || [ "$DRY" = 1 ]; then
      printf '  CLEAN %6s  %s\n' "$(sz "$wt")" "${wt#$PROJECTS_ROOT/}"
    else
      main=$(git -C "$wt" rev-parse --path-format=absolute --git-common-dir 2>/dev/null | sed 's|/\.git$||')
      if git -C "$main" worktree remove --force "$wt" 2>/dev/null; then
        echo "  + removed  ${wt#$PROJECTS_ROOT/}"
      else
        rm -rf "$wt" && git -C "$main" worktree prune 2>/dev/null
        echo "  + removed (rm)  ${wt#$PROJECTS_ROOT/}"
      fi
    fi
  done < <(find "$PROJECTS_ROOT" -type d -path "*/.claude/worktrees/*" -mindepth 3 -maxdepth 6 2>/dev/null)
  echo "  ($clean clean, $kept holding uncommitted or unpushed work)"
fi

after=$(avail_kb)
if [ "$DRY" = 1 ]; then
  echo; echo "Dry run complete. Re-run without --dry-run to execute."
else
  printf '\nFreed ~%.1f GB. Now available: %s\n' \
    "$(awk -v b="$before" -v a="$after" 'BEGIN{print (a-b)/1024/1024}')" \
    "$(df -h / | awk 'NR==2{print $4}')"
fi
