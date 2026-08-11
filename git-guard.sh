#!/usr/bin/env bash
# Projects Git-Guard — pre-flight "is every repo safe to walk away from?" check.
# Companion to warden.sh. Recursively finds every git repo under a root and flags,
# per repo, anything meaning work could be lost or is out of place:
#
#   dirty         uncommitted changes (staged, unstaged, or untracked)
#   off-main→X    current branch is not the repo's trunk X
#                 (trunk auto-detected per repo: origin/HEAD, else main/master/trunk)
#   unpushed:N    N local commits ahead of the branch's upstream
#   no-upstream   branch tracks nothing (work lives only on this machine)
#   no-remote     repo has no remote configured at all
#   detached      HEAD is detached (not on any branch)
#
# Exit 0 = every repo is clean, on trunk, pushed, and tracked.
# Exit 1 = at least one repo raised at least one flag.  (2 = bad usage.)
# Read-only: never runs a write command against any repo. Safe as a deploy/sync gate.
#
# Pruned while scanning: <root>/archive, */.claude/worktrees, node_modules,
# .venv, venv, target, __pycache__. Nested repos elsewhere ARE reported — the point.
set -uo pipefail

usage() {
  cat <<'EOF'
git-guard — flag every git repo under a root that isn't clean, on trunk, and pushed.

  git-guard.sh [root]         scan root (default: ~/Projects); print report + exit code
  git-guard.sh --quiet [root] print only offenders (for cron / chaining); same exit code
  git-guard.sh -h | --help    this help

Flags per repo: dirty, off-main->trunk, unpushed:N, no-upstream, no-remote, detached.
Exit 0 = all clear · 1 = at least one flag · 2 = bad usage. Read-only; never writes.
EOF
}

# ---- args ------------------------------------------------------------------
QUIET=0
ROOT="$HOME/Projects"
for a in "$@"; do
  case "$a" in
    -h|--help) usage; exit 0 ;;
    -q|--quiet) QUIET=1 ;;
    -*) echo "git-guard: unknown option '$a' (try -h)" >&2; exit 2 ;;
    *)  ROOT="${a%/}" ;;
  esac
done
[ -d "$ROOT" ] || { echo "git-guard: no such directory: $ROOT" >&2; exit 2; }

# ---- color (only on a tty) -------------------------------------------------
if [ -t 1 ]; then
  R=$'\033[31m'; Y=$'\033[33m'; G=$'\033[32m'; B=$'\033[1m'; D=$'\033[2m'; X=$'\033[0m'
else
  R=; Y=; G=; B=; D=; X=
fi
ROOTDISP="${ROOT/#$HOME/~}"

# ---- trunk detection (offline; reads local refs only, never the network) ---
trunk_of() {
  local r="$1" t b
  t=$(git -C "$r" symbolic-ref --short -q refs/remotes/origin/HEAD 2>/dev/null)
  if [ -n "$t" ]; then printf '%s' "${t#origin/}"; return; fi
  for b in main master trunk; do
    if git -C "$r" show-ref --verify --quiet "refs/heads/$b"; then printf '%s' "$b"; return; fi
  done
  printf ''
}

flags=""
add() { flags="${flags:+$flags, }$1"; }

# ---- scan ------------------------------------------------------------------
offenders=""
total=0; clean=0; flagged=0; skipped=0

while IFS= read -r -d '' gitpath; do
  repo="${gitpath%/.git}"
  # A .git *file* pointing into a parent's /modules/ store is a pinned submodule —
  # a dependency ref, not standalone work; its detached/no-upstream state is expected.
  if [ -f "$gitpath" ] && grep -q '/modules/' "$gitpath" 2>/dev/null; then
    skipped=$((skipped + 1)); continue
  fi
  git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1 || continue  # skip bare/stray
  total=$((total + 1))
  rel="${repo#"$ROOT"/}"; [ "$rel" = "$repo" ] && rel="$(basename "$repo")"
  flags=""

  # branch vs trunk
  cur=$(git -C "$repo" symbolic-ref --short -q HEAD 2>/dev/null)
  trunk=$(trunk_of "$repo")
  if [ -z "$cur" ]; then
    short=$(git -C "$repo" rev-parse --short HEAD 2>/dev/null || echo '?')
    branchlabel="detached@$short"
    add "${R}detached${X}"
  else
    branchlabel="$cur"
    if [ -n "$trunk" ] && [ "$cur" != "$trunk" ]; then
      add "${R}off-main${X}${D}->$trunk${X}"
    fi
  fi

  # working tree
  if [ -n "$(git -C "$repo" status --porcelain 2>/dev/null)" ]; then
    add "${R}dirty${X}"
  fi

  # remote / upstream / unpushed
  if [ -z "$(git -C "$repo" remote 2>/dev/null)" ]; then
    add "${Y}no-remote${X}"
  else
    up=$(git -C "$repo" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null)
    if [ -z "$up" ]; then
      add "${Y}no-upstream${X}"
    else
      ahead=$(git -C "$repo" rev-list --count '@{upstream}..HEAD' 2>/dev/null || echo 0)
      [ "${ahead:-0}" -gt 0 ] && add "${Y}unpushed:$ahead${X}"
    fi
  fi

  if [ -n "$flags" ]; then
    flagged=$((flagged + 1))
    offenders+="$rel"$'\t'"$branchlabel"$'\t'"$flags"$'\n'
  else
    clean=$((clean + 1))
  fi
done < <(
  find "$ROOT" \
    -path "$ROOT/archive" -prune -o \
    -path '*/.claude/worktrees' -prune -o \
    \( -name node_modules -o -name .venv -o -name venv -o -name target -o -name __pycache__ -o -name .build \) -prune -o \
    -name .git -print0 2>/dev/null
)

# ---- report ----------------------------------------------------------------
skipmsg=""
if [ "$skipped" -gt 0 ] && [ "$QUIET" -eq 0 ]; then
  s=s; [ "$skipped" -eq 1 ] && s=
  skipmsg=$(printf '%s(skipped %d pinned submodule%s)%s' "$D" "$skipped" "$s" "$X")
fi

if [ "$flagged" -gt 0 ]; then
  maxw=$(printf '%s' "$offenders" | awk -F'\t' 'length($1)>m{m=length($1)} END{print (m<18?18:m)}')
  if [ "$QUIET" -eq 0 ]; then
    printf '%sgit-guard%s %s(%s)%s\n' "$B" "$X" "$D" "$ROOTDISP" "$X"
    printf '%d repos * %s%d clean%s * %s%d need attention%s\n\n' \
      "$total" "$G" "$clean" "$X" "$R" "$flagged" "$X"
  fi
  printf '%s' "$offenders" | sort -t$'\t' -k1,1 | while IFS=$'\t' read -r rel br fl; do
    [ -z "$rel" ] && continue
    printf "  ${R}x${X} %-${maxw}s  ${Y}%-16s${X}  %s\n" "$rel" "$br" "$fl"
  done
  [ -n "$skipmsg" ] && printf '\n%s\n' "$skipmsg"
  exit 1
else
  if [ "$QUIET" -eq 0 ]; then
    printf '%s* git-guard: all %d repos under %s are clean, on trunk, and pushed.%s\n' \
      "$G" "$total" "$ROOTDISP" "$X"
    [ -n "$skipmsg" ] && printf '%s\n' "$skipmsg"
  fi
  exit 0
fi
