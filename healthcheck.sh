#!/usr/bin/env bash
# healthcheck.sh: read-only preflight for gws, Fly, tailscale, casa and local daemons.
# Usage: healthcheck.sh [--local-only] [--quiet]
#   --local-only  skip every check that talks to casa
#   --quiet       print only WARN/FAIL lines (and the summary)
# Output: one line per check, "STATUS  id  detail  fix: ...", then "N pass, N warn, N fail".
# Exit 1 if any FAIL. Never changes anything: no restarts, no kills, no writes.
# Never wrap gws in `env -i` (it deletes the Gmail credentials).
set -u

LOCAL_ONLY=0
QUIET=0
for a in "$@"; do
  case "$a" in
    --local-only) LOCAL_ONLY=1 ;;
    --quiet) QUIET=1 ;;
    -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
    *) echo "unknown flag: $a" >&2; exit 2 ;;
  esac
done

NPASS=0 NWARN=0 NFAIL=0
out() {  # status id detail fix
  case "$1" in PASS) NPASS=$((NPASS+1)) ;; WARN) NWARN=$((NWARN+1)) ;; *) NFAIL=$((NFAIL+1)) ;; esac
  [ "$QUIET" = 1 ] && [ "$1" = PASS ] && return 0
  printf '%-4s  %-43s  %-52s  fix: %s\n' "$1" "$2" "$3" "$4"
}

# macOS has no coreutils timeout; perl alarm survives exec and kills the child.
to() { local s="$1"; shift; perl -e 'alarm shift; exec @ARGV or exit 127' "$s" "$@"; }
CASA="casa"
rsh() { to 25 ssh -o ConnectTimeout=8 -o BatchMode=yes "$CASA" "$@"; }
jget() { python3 -c "$1" 2>/dev/null; }  # read JSON (possibly prefixed) on stdin

# ---- 1-3 gws -------------------------------------------------------------
GWS_AUTH="$(to 30 gws auth status 2>/dev/null)"
v="$(printf '%s' "$GWS_AUTH" | jget 'import sys,json;t=sys.stdin.read();print(str(json.loads(t[t.index("{"):]).get("token_valid")).lower())')"
if [ "$v" = true ]; then out PASS gws-token "token_valid=true" "gws auth login"
else out FAIL gws-token "token_valid=${v:-unreadable}" "gws auth login"; fi

miss="$(printf '%s' "$GWS_AUTH" | jget '
import sys,json
t=sys.stdin.read(); s=set(json.loads(t[t.index("{"):]).get("scopes") or [])
full="https://mail.google.com/" in s
need={"gmail.send":full,"gmail.readonly":full,"spreadsheets":False,"calendar":False}
print(" ".join(k for k,ok in need.items() if not ok and "https://www.googleapis.com/auth/"+k not in s))' || echo unreadable)"
if [ -z "$miss" ]; then out PASS gws-scopes "gmail.send gmail.readonly spreadsheets calendar" "gws auth login (re-consent)"
else out FAIL gws-scopes "missing: $miss" "gws auth login (re-consent)"; fi

v="$(to 30 gws gmail users getProfile --params '{"userId":"me"}' 2>/dev/null | jget 'import sys,json;t=sys.stdin.read();print("yes" if json.loads(t[t.index("{"):]).get("emailAddress") else "")')"
if [ "$v" = yes ]; then out PASS gws-gmail-live "getProfile returned emailAddress" "gws auth login"
else out FAIL gws-gmail-live "getProfile failed" "gws auth login"; fi

# ---- 4-7 fly -------------------------------------------------------------
if to 30 fly auth whoami 2>/dev/null | grep -q '@'; then out PASS fly-auth "logged in" "fly auth login"
else out FAIL fly-auth "fly auth whoami failed" "fly auth login"; fi

fly_secrets() {  # app names...
  local app="$1"; shift
  local names miss=""
  names="$(to 40 fly secrets list -a "$app" --json 2>/dev/null | jget 'import sys,json;print(" ".join((x.get("name") or x.get("Name") or "") for x in json.load(sys.stdin)))')"
  if [ -z "$names" ]; then out FAIL "fly-secrets-$app" "could not list secrets" "fly auth login; fly secrets list -a $app"; return; fi
  for n in "$@"; do case " $names " in *" $n "*) ;; *) miss="$miss $n" ;; esac; done
  if [ -z "$miss" ]; then out PASS "fly-secrets-$app" "$# required names present" "fly secrets set <NAME>=... -a $app"
  else out FAIL "fly-secrets-$app" "missing:$miss" "fly secrets set <NAME>=... -a $app"; fi
}
fly_secrets oddmind-hq DATABASE_URL DATABASE_URL_DIRECT BETTER_AUTH_SECRET INGEST_TOKEN ANTHROPIC_API_KEY
fly_secrets oddmind-apps DATABASE_URL DATABASE_URL_DIRECT BETTER_AUTH_SECRET RESEND_API_KEY

for app in oddmind-hq oddmind-apps; do
  st="$(to 40 fly status -a "$app" --json 2>/dev/null | jget 'import sys,json;d=json.load(sys.stdin);ms=d.get("Machines") or [];print(sum(m.get("state")=="started" for m in ms),len(ms))')"
  set -- $st
  if [ -n "${1:-}" ] && [ "${1:-0}" -gt 0 ]; then out PASS "fly-machines-$app" "$1/$2 machines started" "fly machine start -a $app"
  else out FAIL "fly-machines-$app" "${1:-?}/${2:-?} machines started" "fly machine start -a $app"; fi
done

# ---- 8 tailscale (local) -------------------------------------------------
ts="$(to 15 tailscale status --json 2>/dev/null | jget '
import sys,json,datetime
d=json.load(sys.stdin); s=d.get("Self") or {}; k=s.get("KeyExpiry")
days=""
if k:
    e=datetime.datetime.fromisoformat(k.replace("Z","+00:00"))
    days=str(int((e-datetime.datetime.now(datetime.timezone.utc)).total_seconds()//86400))
print(d.get("BackendState"), s.get("Online"), days or "none")')"
set -- $ts
if [ "${1:-}" = Running ] && [ "${2:-}" = True ]; then
  if [ "${3:-none}" != none ] && [ "$3" -lt 14 ]; then out WARN tailscale-local "Running, online, key expires in $3 days" "tailscale up (re-auth before expiry)"
  else out PASS tailscale-local "Running, online, key expiry ${3:-none}d" "tailscale up"; fi
else out FAIL tailscale-local "state=${1:-?} online=${2:-?}" "tailscale up"; fi

# ---- 9-14 casa -----------------------------------------------------------
if [ "$LOCAL_ONLY" = 0 ]; then
  if rsh true >/dev/null 2>&1; then
    out PASS casa-ssh "ssh casa true" "power/tailscale on casa; ssh casa"

    st="$(rsh 'tailscale status --json' 2>/dev/null | jget 'import sys,json;print(json.load(sys.stdin).get("BackendState"))')"
    if [ "$st" = Running ]; then out PASS casa-tailscale "BackendState Running" "run tailscale up on casa (sudo-free box)"
    else out FAIL casa-tailscale "BackendState ${st:-unreadable}" "run tailscale up on casa (sudo-free box)"; fi

    CRON="$(rsh 'crontab -l' 2>/dev/null)"
    while IFS='|' read -r id pat fix; do
      if printf '%s\n' "$CRON" | grep -Eq "$pat"; then out PASS "casa-cron:$id" "marker present" "$fix"
      else out FAIL "casa-cron:$id" "marker missing: $pat" "$fix"; fi
    done <<'EOF'
kalshi-desk|kalshi-desk BEGIN|ssh casa '~/kalshi-desk/cron/install_cron.sh'
crypto-desk|crypto-desk BEGIN|ssh casa '~/crypto-desk/cron/install_cron.sh'
netmap|netmap-run\.sh|re-add the netmap-run.sh lines (@reboot + 1-59/5) to casa crontab
casa-watchdog|casa-watchdog run|re-add the */5 casa-watchdog run line to casa crontab
llm-spend|llm-spend/casa/run-daily\.sh|re-add the llm-spend/casa/run-daily.sh line to casa crontab
nuggest|nuggest.*daily\.sh|re-add the nuggest scripts/daily.sh line to casa crontab
casablanca|casablanca-run\.sh|re-add the casablanca-run.sh lines to casa crontab
EOF

    hl="$(rsh 'cd ~/kalshi-desk 2>/dev/null || { echo nodir; exit 0; }
      pid=$(cat state/hot_loop.pid 2>/dev/null); alive=0
      if [ -n "$pid" ] && test -d "/proc/$pid" && grep -qa hot_loop "/proc/$pid/cmdline" 2>/dev/null; then alive=1; fi
      m=$(stat -c %Y logs/hot_loop.log 2>/dev/null || echo 0); now=$(date +%s)
      halt=0; test -e state/HALT && halt=1
      echo "$alive $((now-m)) $halt"' 2>/dev/null)"
    set -- $hl
    hfix="ssh casa '~/kalshi-desk/scripts/hot_loop_keepalive.sh'"
    if [ "${1:-}" = nodir ] || [ -z "${1:-}" ]; then out FAIL casa-kalshi-hot-loop "could not read ~/kalshi-desk state" "$hfix"
    elif [ "${3:-0}" = 1 ]; then out WARN casa-kalshi-hot-loop "state/HALT present (desk halted); alive=$1 log age ${2}s" "clear HALT only if intended (money-moving)"
    elif [ "$1" = 1 ] && [ "${2:-999999}" -lt 300 ]; then out PASS casa-kalshi-hot-loop "pid alive, log age ${2}s" "$hfix"
    else out FAIL casa-kalshi-hot-loop "alive=$1 log age ${2}s (want alive, <300s)" "$hfix"; fi

    while IFS='|' read -r port name fix; do
      code="$(to 15 curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://casa.tailb77fc.ts.net:$port/" 2>/dev/null)"
      if [ "$code" = 200 ]; then out PASS "casa-site-$name" ":$port HTTP 200" "$fix"
      else out FAIL "casa-site-$name" ":$port HTTP ${code:-none}" "$fix"; fi
    done <<'EOF'
8765|nuggest|ssh casa 'cd ~/Projects/nuggest && scripts/casa/site_run.sh'
8766|kalshi|ssh casa 'cd ~/kalshi-desk && scripts/desk_site_keepalive.sh'
8767|family-wealth|ssh casa '~/family-wealth-site/bin/site-run.sh'
8768|claude-burn|ssh casa '~/claude-burn/casa/site-run.sh'
8769|netmap|ssh casa '~/.local/bin/netmap-run.sh'
8770|llm-spend|ssh casa '~/llm-spend/casa/site-run.sh'
EOF

    if rsh 'pgrep -f "netmap [s]erve"' >/dev/null 2>&1; then out PASS casa-netmap-proc "netmap serve running" "ssh casa ~/.local/bin/netmap-run.sh"
    else out FAIL casa-netmap-proc "no netmap serve process" "ssh casa ~/.local/bin/netmap-run.sh"; fi
  else
    out FAIL casa-ssh "ssh casa true failed" "power/tailscale on casa; ssh casa"
    out WARN casa-checks "casa-tailscale/cron/hot-loop/sites/netmap skipped" "fix casa-ssh first"
  fi
fi

# ---- 15 steno ------------------------------------------------------------
# Socket + protocol from ~/Projects/steno daemon source: DaemonPaths.socketPath,
# newline-delimited JSON, {"cmd":"status"} -> {"ok":..,"status":"idle|starting|
# recording|stopping|error|recovering|paused",..}.
STENO_SOCK="$HOME/Library/Application Support/Steno/steno.sock"
STENO_FIX="printf '{\"cmd\":\"start\"}\\n' | nc -U -w 3 \"$STENO_SOCK\""
if ! launchctl print "gui/$(id -u)/com.steno.daemon" >/dev/null 2>&1; then
  out FAIL steno-daemon "com.steno.daemon not loaded in launchd" "launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.steno.daemon.plist"
elif [ ! -S "$STENO_SOCK" ]; then
  out FAIL steno-daemon "job loaded but no socket (daemon not running)" "launchctl kickstart gui/$(id -u)/com.steno.daemon"
else
  st="$(STENO_SOCK="$STENO_SOCK" to 10 python3 -c '
import json,os,socket
s=socket.socket(socket.AF_UNIX); s.settimeout(5); s.connect(os.environ["STENO_SOCK"])
s.sendall(b"{\"cmd\":\"status\"}\n"); buf=b""
while b"\n" not in buf:
    c=s.recv(65536)
    if not c: break
    buf+=c
d=json.loads(buf.split(b"\n")[0]); print(d.get("status") or ("recording" if d.get("recording") else "unknown"))' 2>/dev/null)"
  case "$st" in
    recording|listening) out PASS steno-daemon "status=$st" "$STENO_FIX" ;;
    paused) out WARN steno-daemon "status=paused (Corey's choice; not resuming)" "$STENO_FIX (only if Corey wants it)" ;;
    starting|recovering|stopping) out WARN steno-daemon "status=$st (transitional)" "re-run in a minute; then $STENO_FIX" ;;
    "") out FAIL steno-daemon "socket present but status query failed" "launchctl kickstart -k gui/$(id -u)/com.steno.daemon" ;;
    *) out FAIL steno-daemon "status=$st" "$STENO_FIX" ;;
  esac
fi

# ---- 16 launchd ----------------------------------------------------------
LL="$(launchctl list 2>/dev/null | awk '{print $3}')"
for label in com.steno.daemon com.corey.housekeeping com.corey.warden com.corey.claude-burn \
             health.oddmind.claude-memory-backup com.corey.gmail-morning-cleanup com.corey.usage-sentinel; do
  if printf '%s\n' "$LL" | grep -qxF "$label"; then out PASS "launchd:$label" "loaded" "launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/$label.plist"
  else out FAIL "launchd:$label" "not in launchctl list" "launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/$label.plist"; fi
done

# ---- 17 claude locks -----------------------------------------------------
LOCKS="$HOME/.claude/locks"
if [ -d "$LOCKS" ]; then
  stale="$(find "$LOCKS" -maxdepth 1 -name '*.lock' -mmin +10 2>/dev/null)"
  if [ -z "$stale" ]; then out PASS claude-locks "no lock older than 600s" "-"
  else while IFS= read -r f; do out WARN claude-locks "stale: $(basename "$f")" "rm \"$f\""; done <<< "$stale"; fi
else
  out PASS claude-locks "no lock dir (ops-guard not installed)" "-"
fi

# ---- 18 geoff dry-run marker --------------------------------------------
M="$HOME/.claude/scheduled-tasks/geoff-daily-mail/DRYRUN"
if [ -e "$M" ]; then out WARN geoff-dryrun-marker "DRYRUN marker present (daily mail will not send)" "rm \"$M\""
else out PASS geoff-dryrun-marker "no DRYRUN marker" "-"; fi

echo "$NPASS pass, $NWARN warn, $NFAIL fail"
[ "$NFAIL" -eq 0 ]
