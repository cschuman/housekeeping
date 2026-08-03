#!/usr/bin/env bash
# usage-sentinel.sh — nightly Claude Code usage watchdog.
#
# Parses ~/.claude/projects/*.jsonl, computes a cost-weighted usage proxy per
# day, and alerts (email via gws) ONLY when today looks anomalous. Silent on
# normal days. Born 2026-07-26 after a single open-ended Opus /loop ate ~53% of
# a week's budget in one day.
#
# Triggers (either fires an alert):
#   1. ANOMALY  — today's proxy > ANOMALY_FACTOR x median of the prior N days
#   2. PACE     — trailing-7-day proxy > WEEKLY_CEILING
#
# NOTE: the JSONL logs contain token counts, NOT your real plan quota. This is a
# cost-weighted proxy (Anthropic list prices) measured against YOUR OWN baseline.
# The dollar figures are relative signal, not your actual bill. Tune the ceiling
# below as you learn what a "normal" week looks like for you.
#
# Usage:
#   ./usage-sentinel.sh            # launchd mode: silent unless triggered (emails)
#   ./usage-sentinel.sh --show     # always print the report to stdout (no email)
#   ./usage-sentinel.sh --email    # force-send the report regardless of triggers
set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:$PATH"

# ---- tunables (env-overridable) -------------------------------------------
PROJECTS_DIR="${CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}"
EMAIL_TO="${SENTINEL_EMAIL_TO:-cschuman@gmail.com}"
ANOMALY_FACTOR="${SENTINEL_ANOMALY_FACTOR:-3}"     # today > 3x median => alert
MEDIAN_WINDOW="${SENTINEL_MEDIAN_WINDOW:-14}"      # days of baseline (excl. today)
WEEKLY_CEILING="${SENTINEL_WEEKLY_CEILING:-5000}"  # trailing-7d proxy $ => alert
LOOKBACK_DAYS=$((MEDIAN_WINDOW + 2))

MODE="launchd"
case "${1:-}" in
  --show)  MODE="show"  ;;
  --email) MODE="email" ;;
esac

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
ROWS="$TMP/rows.tsv"
: > "$ROWS"

# ---- jq: emit  date \t model \t inp \t out \t cr \t cc  per assistant msg ---
cat > "$TMP/extract.jq" <<'JQ'
def toks(u):
  if ((u.iterations // []) | length) > 0 then
    (u.iterations | { inp:(map(.input_tokens//0)|add), out:(map(.output_tokens//0)|add),
      cr:(map(.cache_read_input_tokens//0)|add), cc:(map(.cache_creation_input_tokens//0)|add) })
  else { inp:(u.input_tokens//0), out:(u.output_tokens//0),
         cr:(u.cache_read_input_tokens//0), cc:(u.cache_creation_input_tokens//0) } end;
select(.type=="assistant" and (.message.usage != null))
| ((.timestamp // "")[0:10]) as $d | (.message.model // "unknown") as $m
| toks(.message.usage) as $t
| [$d,$m,$t.inp,$t.out,$t.cr,$t.cc] | @tsv
JQ

while IFS= read -r f; do
  jq -rf "$TMP/extract.jq" "$f" 2>/dev/null >> "$ROWS" || true
done < <(find "$PROJECTS_DIR" -name '*.jsonl' -mtime -"$LOOKBACK_DAYS" 2>/dev/null)

# ---- per-day cost proxy (Anthropic list prices; fable priced as opus) ------
awk -F'\t' '
function w(m,i,o,r,c){
  if (m ~ /opus|fable/) return i*15e-6 + o*75e-6 + r*1.5e-6  + c*18.75e-6;
  else if (m ~ /sonnet/) return i*3e-6  + o*15e-6 + r*0.3e-6  + c*3.75e-6;
  else if (m ~ /haiku/)  return i*0.8e-6+ o*4e-6  + r*0.08e-6 + c*1e-6;
  else                   return i*15e-6 + o*75e-6 + r*1.5e-6  + c*18.75e-6;
}
{ c[$1]+=w($2,$3,$4,$5,$6); o[$1]+=$4; cr[$1]+=$5; n[$1]++ }
END{ for(d in c) printf "%s\t%.2f\t%d\t%d\t%d\n",d,c[d],o[d],cr[d],n[d] }' "$ROWS" \
  | sort > "$TMP/daycost.tsv"

# ---- date windows (BSD date on macOS) -------------------------------------
TODAY="$(date +%Y-%m-%d)"
MEDDATES=""; for i in $(seq 1 "$MEDIAN_WINDOW"); do MEDDATES="$MEDDATES $(date -v-"${i}"d +%Y-%m-%d)"; done
WKDATES="";  for i in $(seq 0 6);              do WKDATES="$WKDATES $(date -v-"${i}"d +%Y-%m-%d)"; done

read -r TODAY_PROXY MEDIAN WEEK7 THRESH TRIGGER < <(
  awk -F'\t' -v today="$TODAY" -v med="$MEDDATES" -v wk="$WKDATES" \
      -v factor="$ANOMALY_FACTOR" -v ceil="$WEEKLY_CEILING" '
  { c[$1]=$2 }
  END{
    tp = (today in c) ? c[today] : 0;
    nm = split(med, md, " "); k=0;
    for (i=1;i<=nm;i++){ d=md[i]; v=(d in c)?c[d]:0; k++; arr[k]=v }
    # median of k values
    for (i=1;i<=k;i++) for (j=i+1;j<=k;j++) if (arr[j]<arr[i]){ t=arr[i];arr[i]=arr[j];arr[j]=t }
    if (k==0) m=0; else if (k%2) m=arr[int(k/2)+1]; else m=(arr[k/2]+arr[k/2+1])/2;
    nw=split(wk, wd, " "); w7=0; for(i=1;i<=nw;i++){ d=wd[i]; w7 += (d in c)?c[d]:0 }
    thr = m*factor;
    trig = ((tp > thr && tp > 1) || (w7 > ceil)) ? 1 : 0;
    printf "%.2f %.2f %.2f %.2f %d", tp, m, w7, thr, trig;
  }' "$TMP/daycost.tsv"
)

# ---- decide + build report -------------------------------------------------
REASONS=""
awk_gt(){ awk -v a="$1" -v b="$2" 'BEGIN{exit !(a>b)}'; }
if awk_gt "$TODAY_PROXY" "$THRESH" && awk_gt "$TODAY_PROXY" 1; then
  REASONS="${REASONS}• ANOMALY: today \$${TODAY_PROXY} > ${ANOMALY_FACTOR}× median (\$${MEDIAN}) = \$${THRESH}\n"
fi
if awk_gt "$WEEK7" "$WEEKLY_CEILING"; then
  REASONS="${REASONS}• PACE: trailing-7-day \$${WEEK7} > ceiling \$${WEEKLY_CEILING}\n"
fi

build_report(){
  {
    echo "Claude usage sentinel — $(date '+%a %b %d, %I:%M %p')"
    echo "================================================"
    if [ -n "$REASONS" ]; then echo "STATUS: ALERT"; printf "%b" "$REASONS"
    else echo "STATUS: normal (all clear)"; fi
    echo
    printf "  today (%s) proxy : \$%s\n" "$TODAY" "$TODAY_PROXY"
    printf "  %d-day median/day : \$%s   (alert if today > \$%s)\n" "$MEDIAN_WINDOW" "$MEDIAN" "$THRESH"
    printf "  trailing 7 days   : \$%s   (ceiling \$%s)\n" "$WEEK7" "$WEEKLY_CEILING"
    echo
    echo "Last 15 days (proxy \$ / output tok / cache-rd / msgs):"
    tail -15 "$TMP/daycost.tsv" | sort -r | awk -F'\t' \
      '{printf "  %-11s  \$%9.2f  %10d out  %12d rd  %6d msgs\n",$1,$2,$3,$4,$5}'
    # culprit breakdown only when something tripped
    if [ -n "$REASONS" ]; then
      echo
      echo "Today by project (what drove it):"
      find "$PROJECTS_DIR" -name '*.jsonl' -mtime -2 2>/dev/null | while IFS= read -r f; do
        proj=$(basename "$(dirname "$f")")
        [ "$proj" = "subagents" ] && proj="$(basename "$(dirname "$(dirname "$f")")")/subagents"
        cnt=$(jq -r --arg D "$TODAY" 'select(.type=="assistant" and ((.timestamp//"")[0:10]==$D))|1' "$f" 2>/dev/null | wc -l | tr -d ' ')
        [ "${cnt:-0}" -gt 0 ] && echo "$cnt $proj"
      done | awk '{a[$2]+=$1} END{for(p in a) print a[p]"\t"p}' | sort -rn | head -8 \
        | awk -F'\t' '{printf "  %6d msgs  %s\n",$1,$2}'
      echo
      echo "First move: is a /loop or Workflow still running on Opus/Fable? Bound or kill it."
    fi
  }
}

REPORT="$TMP/report.txt"
build_report > "$REPORT"

# refresh the HTML dashboard alongside the nightly check (best-effort)
DIR_SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -x "$DIR_SELF/usage-dashboard.sh" ] && "$DIR_SELF/usage-dashboard.sh" >/dev/null 2>&1 || true

send_email(){
  local subj="$1"
  local html="<pre style=\"font-family:ui-monospace,Menlo,monospace;font-size:13px\">$(sed 's/&/\&amp;/g;s/</\&lt;/g;s/>/\&gt;/g' "$REPORT")</pre>"
  gws gmail +send --to "$EMAIL_TO" --subject "$subj" --body "$html" --html >/dev/null 2>&1 \
    || gws gmail +send --to "$EMAIL_TO" --subject "$subj" --body "$(cat "$REPORT")" >/dev/null 2>&1
}

case "$MODE" in
  show)  cat "$REPORT" ;;
  email) cat "$REPORT"; send_email "Claude usage — $(date '+%b %d')" ;;
  launchd)
    if [ -n "$REASONS" ]; then
      cat "$REPORT"   # goes to launchd log
      send_email "⚠️ Claude usage spike — $(date '+%b %d')"
    else
      echo "$(date '+%F %T')  all clear (today \$$TODAY_PROXY, 7d \$$WEEK7)"
    fi
    ;;
esac
