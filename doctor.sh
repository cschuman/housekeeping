#!/usr/bin/env bash
# doctor.sh — guard against regressions of common shell-startup optimizations.
# READ ONLY. Generic where possible; tool-specific checks run only if that tool is
# configured, so it degrades gracefully on any machine.
# Exits nonzero if any check warns (CI / monitor friendly).
set -uo pipefail

ZSHRC="$HOME/.zshrc"
warns=0
pass(){ printf '  \033[32m✓\033[0m %s\n' "$1"; }
warn(){ printf '  \033[33m!\033[0m %s\n      → %s\n' "$1" "$2"; warns=$((warns+1)); }
info(){ printf '  \033[2m·\033[0m %s\n' "$1"; }

printf '\033[1mhousekeeping doctor — shell startup regression check\033[0m\n\n'

# 1. Interactive startup time (warm: take 2nd run)
if command -v zsh >/dev/null; then
  { /usr/bin/time zsh -i -c exit; } >/dev/null 2>&1
  t=$( { /usr/bin/time zsh -i -c exit; } 2>&1 | awk '/real/{print $1}' )
  thresh=0.5
  if awk "BEGIN{exit !(${t:-99} > $thresh)}"; then
    warn "zsh startup ${t}s (over ${thresh}s)" "profile: zsh -i -c 'zmodload zsh/zprof; source ~/.zshrc; zprof' | head -20"
  else
    pass "zsh startup ${t}s"
  fi
fi

# 2. Duplicate PATH entries
dupes=$(printf '%s' "$PATH" | tr ':' '\n' | sort | uniq -d | tr '\n' ' ')
if [ -n "${dupes// /}" ]; then
  warn "duplicate \$PATH entries: $dupes" "add 'typeset -U path PATH' early in ~/.zshrc, or remove the duplicate export"
else
  pass "no duplicate \$PATH entries"
fi

[ -f "$ZSHRC" ] || { printf '\n(no ~/.zshrc; shell checks skipped)\n'; exit $(( warns > 0 )); }

# 3. Uncached completion generation (the openclaw class of regression)
if grep -Eq 'source <\(.*completion|eval "\$\(.*completion' "$ZSHRC"; then
  warn "a shell completion is generated on every launch" "cache it to a file and source that; regenerate only when the tool binary is newer (see README)"
else
  pass "no uncached completion generation"
fi

# 4. nvm eager-load (costs ~0.8s if not lazy)
if [ -d "$HOME/.nvm" ]; then
  if grep -Eq 'nvm\.sh' "$ZSHRC" && ! grep -Eq '_load_nvm|lazy|function nvm|nvm\(\)' "$ZSHRC"; then
    warn "nvm appears eagerly sourced (~0.8s/launch)" "wrap nvm/node/npm/npx in lazy-load functions that source nvm.sh on first use"
  else
    pass "nvm not eagerly loaded"
  fi
fi

# 5. oh-my-zsh auto-update (periodic blocking network call)
if [ -d "$HOME/.oh-my-zsh" ]; then
  if grep -Eq '^[[:space:]]*DISABLE_AUTO_UPDATE="true"' "$ZSHRC" || grep -Eq "zstyle ':omz:update' mode disabled" "$ZSHRC"; then
    pass "oh-my-zsh auto-update disabled"
  else
    warn "oh-my-zsh auto-update enabled (periodic blocking git/curl)" "add to ~/.zshrc: zstyle ':omz:update' mode disabled"
  fi
fi

# 6. compdump hygiene (informational)
n=$(ls -1 "$HOME"/.zcompdump* 2>/dev/null | wc -l | tr -d ' ')
[ "${n:-0}" -gt 2 ] && info "$n .zcompdump files present (stale ones from old hosts/versions can be pruned)"

printf '\n'
if [ "$warns" -eq 0 ]; then
  printf '\033[1;32mAll checks passed.\033[0m\n'; exit 0
else
  printf '\033[1;33m%d regression(s) found — see fixes above.\033[0m\n' "$warns"; exit 1
fi
