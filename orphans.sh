#!/usr/bin/env bash
# orphans.sh — find launchd jobs and system extensions whose owning software is gone.
# READ ONLY. Catches half-uninstalled cruft: daemons, agents, and kernel/network
# extensions left running after the app that owned them was deleted. Almost nothing
# else detects this, and it is one of the sneakiest sources of leftover background load.
set -uo pipefail

found=0
hit(){ printf '  \033[33m✗ ORPHAN\033[0m  %s\n            %s\n' "$1" "$2"; found=$((found+1)); }
ok(){  printf '  \033[32m✓\033[0m %s\n' "$1"; }
pb(){ /usr/libexec/PlistBuddy -c "$1" "$2" 2>/dev/null; }

printf '\033[1mhousekeeping orphans — leftover daemons / agents / system extensions\033[0m\n\n'

# --- launchd jobs whose program file no longer exists -----------------------
scan_dir(){
  local dir="$1" label="$2" any=0
  [ -d "$dir" ] || return
  printf '\033[36m%s\033[0m  \033[2m%s\033[0m\n' "$label" "$dir"
  for plist in "$dir"/*.plist; do
    [ -e "$plist" ] || continue
    local base; base=$(basename "$plist" .plist)
    case "$base" in com.apple.*) continue;; esac
    local exe
    exe=$(pb "Print :BundleProgram" "$plist")
    [ -z "$exe" ] && exe=$(pb "Print :Program" "$plist")
    [ -z "$exe" ] && exe=$(pb "Print :ProgramArguments:0" "$plist")
    [ -z "$exe" ] && continue
    case "$exe" in
      /*) if [ ! -e "$exe" ]; then hit "$base" "missing program: $exe"; any=1; fi ;;
      *)  : ;;   # bare command on PATH or relative path — can't verify, skip
    esac
  done
  [ "$any" = 0 ] && ok "no orphaned jobs"
  printf '\n'
}

scan_dir "/Library/LaunchDaemons"      "System LaunchDaemons"
scan_dir "/Library/LaunchAgents"       "System LaunchAgents"
scan_dir "$HOME/Library/LaunchAgents"  "User LaunchAgents"

# --- system extensions whose owning app is not installed --------------------
printf '\033[36mSystem extensions\033[0m\n'
if command -v systemextensionsctl >/dev/null 2>&1; then
  # Build a set of installed app bundle-id vendor prefixes (first two components).
  vendors=""
  for app in /Applications/*.app "$HOME"/Applications/*.app /Applications/*/*.app; do
    [ -e "$app/Contents/Info.plist" ] || continue
    appid=$(pb "Print :CFBundleIdentifier" "$app/Contents/Info.plist")
    [ -n "$appid" ] && vendors="$vendors $(printf '%s' "$appid" | cut -d. -f1-2)"
  done

  sx_any=0
  while IFS= read -r line; do
    # data rows are tab-separated: enabled  active  teamID  bundleID (ver)  name  [state]
    bid=$(printf '%s' "$line" | awk -F'\t' 'NF>=4{print $4}' | awk '{print $1}')
    [ -z "$bid" ] && continue
    case "$bid" in com.apple.*|bundleID) continue;; esac
    vendor=$(printf '%s' "$bid" | cut -d. -f1-2)
    case " $vendors " in
      *" $vendor "*) ok "$bid  (owning app present)" ;;
      *) hit "$bid" "no app with vendor prefix '$vendor' found in /Applications — verify owner"; sx_any=1 ;;
    esac
  done < <(systemextensionsctl list 2>/dev/null | grep -E $'\t')
  [ "$sx_any" = 0 ] && [ "$found" = 0 ] && ok "no orphaned extensions"
else
  ok "systemextensionsctl unavailable (skipped)"
fi

printf '\n'
if [ "$found" -eq 0 ]; then
  printf '\033[1;32mNo orphans found.\033[0m\n'
else
  cat <<'EOF'

How to clean up an orphan:
  launchd job (user):   launchctl bootout gui/$(id -u)/<label>;  rm ~/Library/LaunchAgents/<label>.plist
  launchd job (system): sudo launchctl bootout system/<label>;   sudo rm /Library/Launch*/<label>.plist
  system extension:     use the vendor's official uninstaller (network/kernel extensions
                        must be deactivated through the owning app's API, not rm). If the app
                        is already gone, reinstall it, run its uninstaller, then remove it.
EOF
  exit 1
fi
