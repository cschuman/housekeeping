#!/usr/bin/env bash
# usage-dashboard.sh — generate a self-contained HTML view of Claude Code usage.
#
# Reads ALL of ~/.claude/projects/*.jsonl, computes a cost-weighted usage proxy,
# and writes usage-dashboard.html (no external deps — inline CSS, server-rendered
# bars, native hover tooltips). Full scan is ~3s. Regenerated nightly by
# usage-sentinel.sh, or run on demand:  ./usage-dashboard.sh
#
# Dollars are a proxy from Anthropic list prices measured against your own
# baseline — relative signal, NOT your real plan quota (quota isn't in the logs).
set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:$PATH"

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECTS_DIR="${CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}"
OUT="${USAGE_DASHBOARD_OUT:-$DIR/usage-dashboard.html}"
ANOMALY_FACTOR="${SENTINEL_ANOMALY_FACTOR:-3}"
MEDIAN_WINDOW="${SENTINEL_MEDIAN_WINDOW:-14}"
WEEKLY_CEILING="${SENTINEL_WEEKLY_CEILING:-5000}"   # weekly proxy-$ target (also the sentinel alert ceiling)
WEEK_ANCHOR_DOW="${USAGE_WEEK_ANCHOR_DOW:-1}"        # week resets on: 1=Mon..7=Sun (match your plan's reset day)
DAYS="${USAGE_DASHBOARD_DAYS:-30}"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
ROWS="$TMP/rows.tsv"

cat > "$TMP/extract.jq" <<'JQ'
def toks(u):
  if ((u.iterations // []) | length) > 0 then
    (u.iterations | { i:(map(.input_tokens//0)|add), o:(map(.output_tokens//0)|add),
      cr:(map(.cache_read_input_tokens//0)|add), cc:(map(.cache_creation_input_tokens//0)|add) })
  else { i:(u.input_tokens//0), o:(u.output_tokens//0),
         cr:(u.cache_read_input_tokens//0), cc:(u.cache_creation_input_tokens//0) } end;
(fromjson? // empty)
| select(.type=="assistant" and (.message.usage != null))
| (input_filename) as $f | ((.timestamp // "")[0:10]) as $d | (.message.model // "?") as $m
| toks(.message.usage) as $t | [$f,$d,$m,$t.i,$t.o,$t.cr,$t.cc] | @tsv
JQ

# ---- one serial full scan: path date model inp out cr cc ------------------
# NOTE: -R (raw line input) + fromjson? is deliberate. The current session's
# .jsonl is being appended live; a half-written final line makes a normal
# `jq -f` abort the ENTIRE stream, silently dropping every file after it in the
# batch (row counts swung 28k/43k/68k run-to-run). Reading line-by-line and
# parsing with fromjson? skips only the bad line and keeps going.
( cd "$PROJECTS_DIR" && find . -name '*.jsonl' -print0 | xargs -0 jq -Rrf "$TMP/extract.jq" 2>/dev/null ) > "$ROWS" || true

# shared awk cost weight + project-name cleaner
# w(): PER-MODEL list prices (USD/token), matched on the exact model id the log
# recorded — so cost reflects the model that actually ran, not a flat tier guess.
# Tokens (not dollars) are archived, so editing a rate below reprices ALL history.
# >>> To correct a price, change only the four multipliers on that model's line. <<<
AWKLIB='
function w(m,i,o,r,c){
  if(m=="claude-opus-4-8"||m=="claude-opus-5")         return i*15e-6 +o*75e-6 +r*1.5e-6 +c*18.75e-6;   # Opus 4.8 / Opus 5
  else if(m=="claude-fable-5")                          return i*15e-6 +o*75e-6 +r*1.5e-6 +c*18.75e-6;   # Fable 5  (seeded = Opus; edit if Fable differs)
  else if(m=="claude-sonnet-5"||m=="claude-sonnet-4-6") return i*3e-6  +o*15e-6 +r*0.3e-6 +c*3.75e-6;    # Sonnet 5 / Sonnet 4.6
  else if(m=="claude-haiku-4-5-20251001")               return i*0.8e-6+o*4e-6  +r*0.08e-6+c*1e-6;       # Haiku 4.5
  else if(m=="<synthetic>")                             return 0;                                        # synthetic = no cost
  else if(m~/opus|fable/)                               return i*15e-6+o*75e-6+r*1.5e-6+c*18.75e-6;      # unknown frontier -> Opus rate
  else if(m~/sonnet/)                                   return i*3e-6 +o*15e-6+r*0.3e-6+c*3.75e-6;       # unknown sonnet
  else if(m~/haiku/)                                    return i*0.8e-6+o*4e-6+r*0.08e-6+c*1e-6;         # unknown haiku
  else                                                  return i*15e-6+o*75e-6+r*1.5e-6+c*18.75e-6 }     # default -> frontier
function proj(p,  s){ sub(/^.*\/projects\//,"",p); sub(/^\.\//,"",p); s=p; sub(/\/.*/,"",s);
  if(s~/^wf_/)return "workflows"; sub(/^-Users-corey-Projects-?/,"",s); if(s=="")s="Projects (root)";
  if(s~/-?-claude-worktrees-/){sub(/-?-claude-worktrees-.*/,"",s); s=s" (worktree)"} return s }
function valid(d){ return (d ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/) }
function grp(v, dec,   sign,fmt,s,n,ip,fp,out,i,c){   # 4654 -> 4,654 ; dec = decimal places
  if(v<0){sign="-";v=-v}else sign="";
  fmt=(dec+0>0)?("%."dec"f"):"%.0f"; s=sprintf(fmt,v);
  n=index(s,"."); if(n){ip=substr(s,1,n-1);fp=substr(s,n)}else{ip=s;fp=""}
  out=""; c=0; for(i=length(ip);i>=1;i--){out=substr(ip,i,1) out; c++; if(c%3==0&&i>1)out="," out}
  return sign out fp }
function kfmt(x){   # compact: 2.8 / 340 / 1.4K / 34.0K / 2.1M
  if(x>=1e6)return sprintf("%.1fM",x/1e6);
  else if(x>=1e3)return sprintf("%.1fK",x/1e3);
  else if(x>=100)return sprintf("%.0f",x);
  else return sprintf("%.1f",x) }
function mname(m){   # exact model id -> friendly label
  if(m=="claude-opus-4-8")return "Opus 4.8";
  else if(m=="claude-opus-5")return "Opus 5";
  else if(m=="claude-fable-5")return "Fable 5";
  else if(m=="claude-sonnet-5")return "Sonnet 5";
  else if(m=="claude-sonnet-4-6")return "Sonnet 4.6";
  else if(m~/haiku/)return "Haiku 4.5";
  else if(m=="<synthetic>")return "synthetic";
  else return m }
'

# ---- roll current per-message ROWS into a persistent daily archive --------
# Raw .jsonl logs are auto-pruned by Claude Code after cleanupPeriodDays, so we
# bank a per-day/project/model rollup (TOKENS, not $) that outlives them. Each
# run recomputes rollups for the dates still present in the logs and REPLACES
# those dates in the archive, keeping every older archived date untouched. All
# panels below read the archive, so history grows past the raw-log window.
# archive cols: 1 date · 2 proj · 3 model · 4 msgs · 5 inp · 6 out · 7 cr · 8 cc
ARCHIVE="${USAGE_HISTORY_TSV:-$DIR/usage-history.tsv}"
FRESH="$TMP/fresh.tsv"
awk -F'\t' "$AWKLIB"'valid($2){k=$2 SUBSEP proj($1) SUBSEP $3; n[k]++; i[k]+=$4; o[k]+=$5; r[k]+=$6; cc[k]+=$7}
  END{for(k in n){split(k,a,SUBSEP); printf "%s\t%s\t%s\t%d\t%d\t%d\t%d\t%d\n",a[1],a[2],a[3],n[k],i[k],o[k],r[k],cc[k]}}' \
  "$ROWS" > "$FRESH"
if [ -s "$FRESH" ]; then
  cut -f1 "$FRESH" | sort -u > "$TMP/freshdates"
  if [ -f "$ARCHIVE" ]; then
    awk -F'\t' 'NR==FNR{fd[$1]=1;next} !($1 in fd)' "$TMP/freshdates" "$ARCHIVE" > "$TMP/kept"
  else : > "$TMP/kept"; fi
  cat "$TMP/kept" "$FRESH" | sort -t"$(printf '\t')" -k1,1 -k2,2 -k3,3 > "$TMP/merged" && mv "$TMP/merged" "$ARCHIVE"
fi
[ -f "$ARCHIVE" ] || : > "$ARCHIVE"

# ---- per-day proxy from the archive: date cost out cr msgs ----------------
awk -F'\t' "$AWKLIB"'valid($1){c[$1]+=w($3,$5,$6,$7,$8);o[$1]+=$6;cr[$1]+=$7;n[$1]+=$4}
END{for(d in c)printf "%s\t%.2f\t%d\t%d\t%d\n",d,c[d],o[d],cr[d],n[d]}' "$ARCHIVE" | sort > "$TMP/daycost.tsv"

TODAY="$(date +%F)"; CUT7="$(date -v-6d +%F)"; CUT14="$(date -v-13d +%F)"; MSTART="$(date +%Y-%m-01)"
MONTH_LABEL="$(date '+%b %Y')"
MEDDATES=""; for i in $(seq 1 "$MEDIAN_WINDOW"); do MEDDATES="$MEDDATES $(date -v-"${i}"d +%F)"; done

# ---- totals + baseline stats ----------------------------------------------
read -r T_DAY T_WEEK T_MONTH T_ALL EARLIEST MEDIAN MAXV N_DAY N_WEEK N_MONTH N_ALL < <(awk -F'\t' \
  -v today="$TODAY" -v cut7="$CUT7" -v mstart="$MSTART" -v med="$MEDDATES" '
  { c[$1]=$2; all+=$2; alln+=$5; if($1==today){td=$2;tdn=$5} if($1>=cut7){wk+=$2;wkn+=$5} if($1>=mstart){mo+=$2;mon+=$5}
    if(min==""||$1<min)min=$1; if($2>mx)mx=$2 }
  END{ nm=split(med,md," "); k=0; for(i=1;i<=nm;i++){k++;a[k]=(md[i] in c)?c[md[i]]:0}
    for(i=1;i<=k;i++)for(j=i+1;j<=k;j++)if(a[j]<a[i]){t=a[i];a[i]=a[j];a[j]=t}
    m=(k==0)?0:(k%2?a[int(k/2)+1]:(a[k/2]+a[k/2+1])/2);
    printf "%.2f %.2f %.2f %.2f %s %.2f %.2f %d %d %d %d", td+0,wk+0,mo+0,all+0,min,m,mx,tdn+0,wkn+0,mon+0,alln+0 }' "$TMP/daycost.tsv")

THRESH=$(awk -v m="$MEDIAN" -v f="$ANOMALY_FACTOR" 'BEGIN{printf "%.2f",m*f}')
WEEKPCT=$(awk -v a="$T_WEEK" -v b="$WEEKLY_CEILING" 'BEGIN{printf "%.0f",(b>0?a/b*100:0)}')
STATUS="normal"; SCLASS="ok"
awk -v a="$T_DAY" -v b="$THRESH" 'BEGIN{exit !(a>b&&a>1)}' && { STATUS="anomaly today"; SCLASS="hot"; }
awk -v a="$T_WEEK" -v b="$WEEKLY_CEILING" 'BEGIN{exit !(a>b)}' && { STATUS="over weekly pace"; SCLASS="hot"; }
EARLY_LABEL=$(awk -v d="$EARLIEST" 'BEGIN{n=split(d,p,"-"); mo["01"]="Jan";mo["02"]="Feb";mo["03"]="Mar";mo["04"]="Apr";mo["05"]="May";mo["06"]="Jun";mo["07"]="Jul";mo["08"]="Aug";mo["09"]="Sep";mo["10"]="Oct";mo["11"]="Nov";mo["12"]="Dec"; printf "since %s %d",mo[p[2]],p[3]+0}')

money(){ awk -v v="$1" "$AWKLIB"'BEGIN{ printf "$%s", grp(v,0) }'; }
comma(){ awk -v v="$1" "$AWKLIB"'BEGIN{ printf "%s", grp(v,0) }'; }
NDAYS=$(awk 'END{print NR}' "$TMP/daycost.tsv")
RANGE_LABEL=$(awk -v e="$EARLIEST" -v t="$TODAY" 'BEGIN{
  split(e,a,"-"); split(t,b,"-");
  mo["01"]="Jan";mo["02"]="Feb";mo["03"]="Mar";mo["04"]="Apr";mo["05"]="May";mo["06"]="Jun";
  mo["07"]="Jul";mo["08"]="Aug";mo["09"]="Sep";mo["10"]="Oct";mo["11"]="Nov";mo["12"]="Dec";
  if(a[1]==b[1]) printf "%s %d – %s %d, %s",mo[a[2]],a[3]+0,mo[b[2]],b[3]+0,b[1];
  else printf "%s %d, %s – %s %d, %s",mo[a[2]],a[3]+0,a[1],mo[b[2]],b[3]+0,b[1] }')

# ---- 30-day trend series (filled) -----------------------------------------
for i in $(seq $((DAYS-1)) -1 0); do date -v-"${i}"d +%F; done > "$TMP/dates"
awk 'NR==FNR{c[$1]=$2;m[$1]=$5;next}{printf "%s\t%.2f\t%d\n",$1,($1 in c?c[$1]:0),($1 in m?m[$1]:0)}' \
  "$TMP/daycost.tsv" "$TMP/dates" > "$TMP/series"

# chart normalizes to the peak WITHIN the shown window, not all-time
CHARTMAX=$(awk -F'\t' 'BEGIN{m=0}{if($2>m)m=$2}END{printf "%.2f",m}' "$TMP/series")
DAILY_HTML=$(awk -F'\t' -v max="$CHARTMAX" -v thr="$THRESH" "$AWKLIB"'BEGIN{i=0}{
  h=(max>0)?int($2/max*185):0; if(h<1&&$2>0)h=1;
  hot=($2>thr&&$2>1); split($1,d,"-");
  lab=(hot||i%5==0)?d[2]"/"d[3]:"";
  printf "<div class=\"col\"><div class=\"bar%s\" style=\"height:%dpx\" data-d=\"%s\" data-c=\"%.2f\" data-m=\"%d\" title=\"%s — $%s · %s msgs\"></div><div class=\"xl%s\">%s</div></div>",(hot?" hot":""),h,$1,$2,$3,$1,grp($2,0),grp($3,0),(hot?" hotl":""),lab; i++
}' "$TMP/series")
THRPOS=$(awk -v t="$THRESH" -v m="$CHARTMAX" 'BEGIN{printf "%.1f",(m>0?t/m*185:0)}')

# ---- model mix (last 7d) --------------------------------------------------
read -r M_OP M_FA M_SO M_HA M_TOT < <(awk -F'\t' "$AWKLIB"'valid($1)&&$1>=cut7{cst=w($3,$5,$6,$7,$8);
  if($3~/opus/)op+=cst;else if($3~/fable/)fa+=cst;else if($3~/sonnet/)so+=cst;else if($3~/haiku/)ha+=cst;else op+=cst;tot+=cst}
  END{printf "%.2f %.2f %.2f %.2f %.2f",op,fa,so,ha,tot}' cut7="$CUT7" "$ARCHIVE")
seg(){ awk -v v="$1" -v t="$2" 'BEGIN{printf "%.1f",(t>0?v/t*100:0)}'; }
MP_OP=$(seg "$M_OP" "$M_TOT"); MP_FA=$(seg "$M_FA" "$M_TOT"); MP_SO=$(seg "$M_SO" "$M_TOT"); MP_HA=$(seg "$M_HA" "$M_TOT")
MF_OP=$(money "$M_OP"); MF_FA=$(money "$M_FA"); MF_SO=$(money "$M_SO"); MF_HA=$(money "$M_HA")

# ---- per-project (last 7d) with model mix + insights ----------------------
# emit: cost msgs op fa so ha crshare project
PROJAGG=$(awk -F'\t' "$AWKLIB"'valid($1)&&$1>=cut7{p=$2; cst=w($3,$5,$6,$7,$8);
  c[p]+=cst; n[p]+=$4; tok[p]+=$5+$6+$7+$8; crt[p]+=$7;
  if($3~/opus/)op[p]+=cst;else if($3~/fable/)fa[p]+=cst;else if($3~/sonnet/)so[p]+=cst;else if($3~/haiku/)ha[p]+=cst;else op[p]+=cst }
  END{for(p in c)printf "%.2f\t%d\t%.2f\t%.2f\t%.2f\t%.2f\t%.0f\t%s\n",c[p],n[p],op[p],fa[p],so[p],ha[p],(tok[p]>0?crt[p]/tok[p]*100:0),p}' \
  cut7="$CUT7" "$ARCHIVE" | sort -t$'\t' -k1 -rn | head -8)

# one bar per project: its WIDTH = relative cost, its SEGMENTS = model mix
PROJ_HTML=$(printf "%s\n" "$PROJAGG" | awk -F'\t' "$AWKLIB"'BEGIN{first=1}
{ if($8==""){next} if(first){max=$1;first=0}
  cost=$1; msgs=$2; op=$3;fa=$4;so=$5;ha=$6; crs=$7; name=$8;
  tot=(cost>0)?cost:1; pop=op/tot*100;pfa=fa/tot*100;pso=so/tot*100;pha=ha/tot*100;
  wpc=(max>0)?cost/max*100:0; if(cost>0&&wpc<3)wpc=3;
  marathon=(crs>=95 && msgs>=500);
  cap="";
  if(pop>=5)cap=cap (cap==""?"":" · ") sprintf("<span class=\"o\">Opus %.0f%%</span>",pop);
  if(pfa>=5)cap=cap (cap==""?"":" · ") sprintf("<span class=\"f\">Fable %.0f%%</span>",pfa);
  if(pso>=5)cap=cap (cap==""?"":" · ") sprintf("<span class=\"s\">Sonnet %.0f%%</span>",pso);
  if(pha>=5)cap=cap (cap==""?"":" · ") sprintf("<span class=\"h\">Haiku %.0f%%</span>",pha);
  crcls=(crs>=95)?" hicr":"";
  printf "<div class=\"pcard\">";
  printf "<div class=\"pl1\"><span class=\"pname\" title=\"%s\">%s</span>%s<span class=\"pcost\">$%s</span></div>",name,name,(marathon?"<span class=\"flag\" title=\"cache-read very high across many turns — a long-marathon session pattern (the turns x context tax)\">marathon</span>":""),grp(cost,0);
  printf "<div class=\"pbarwrap\" style=\"width:%.1f%%\"><div class=\"mmini\">",wpc;
  if(pop>0)printf "<div class=\"s-op\" style=\"flex:%.3f\" title=\"Opus $%s (%.0f%%)\"></div>",pop,grp(op,0),pop;
  if(pfa>0)printf "<div class=\"s-fa\" style=\"flex:%.3f\" title=\"Fable $%s (%.0f%%)\"></div>",pfa,grp(fa,0),pfa;
  if(pso>0)printf "<div class=\"s-so\" style=\"flex:%.3f\" title=\"Sonnet $%s (%.0f%%)\"></div>",pso,grp(so,0),pso;
  if(pha>0)printf "<div class=\"s-ha\" style=\"flex:%.3f\" title=\"Haiku $%s (%.0f%%)\"></div>",pha,grp(ha,0),pha;
  printf "</div></div>";
  printf "<div class=\"pl3\">%s msgs · %s · <span class=\"cr%s\">%.0f%% cache-read</span></div>",grp(msgs,0),cap,crcls,crs;
  printf "</div>" }')

# ---- lifetime by project (all-time, every project) ------------------------
# emit: cost msgs project   — ranked by all-time cost
LIFEAGG=$(awk -F'\t' "$AWKLIB"'valid($1){p=$2; c[p]+=w($3,$5,$6,$7,$8); n[p]+=$4}
  END{for(p in c)printf "%.2f\t%d\t%s\n",c[p],n[p],p}' "$ARCHIVE" | sort -t$'\t' -k1 -rn | head -16)
LIFE_HTML=$(printf "%s\n" "$LIFEAGG" | awk -F'\t' "$AWKLIB"'BEGIN{first=1}
{ if($3==""){next} if(first){max=$1;first=0}
  cost=$1; msgs=$2; name=$3; wpc=(max>0)?cost/max*100:0;
  d=sprintf("$%s",grp(cost,0));
  printf "<div class=\"lrow\"><div class=\"lname\" title=\"%s\">%s</div><div class=\"ltrack\"><div class=\"lbar\" style=\"width:%.1f%%\"></div></div><div class=\"lmsg\">%s msgs</div><div class=\"lcost\">%s</div></div>",name,name,wpc,grp(msgs,0),d }')

# ---- weekly budget target & pacing ----------------------------------------
case "$WEEK_ANCHOR_DOW" in 1)ANCHORNAME=Monday;;2)ANCHORNAME=Tuesday;;3)ANCHORNAME=Wednesday;;4)ANCHORNAME=Thursday;;5)ANCHORNAME=Friday;;6)ANCHORNAME=Saturday;;7)ANCHORNAME=Sunday;;*)ANCHORNAME=Monday;WEEK_ANCHOR_DOW=1;;esac
: > "$TMP/weeks.tsv"
# bucket each active day into its week-start (anchored to WEEK_ANCHOR_DOW)
while IFS=$'\t' read -r d cost _o _cr msgs; do
  dow=$(date -j -f %Y-%m-%d "$d" +%u 2>/dev/null) || continue
  off=$(( (dow - WEEK_ANCHOR_DOW + 7) % 7 ))
  ws=$(date -j -v-"${off}"d -f %Y-%m-%d "$d" +%F 2>/dev/null) || continue
  printf "%s\t%s\t%s\n" "$ws" "$cost" "$msgs"
done < "$TMP/daycost.tsv" \
  | awk -F'\t' '{c[$1]+=$2;n[$1]+=$3} END{for(w in c)printf "%s\t%.2f\t%d\n",w,c[w],n[w]}' \
  | sort > "$TMP/weeks.tsv"

TDOW=$(date -j -f %Y-%m-%d "$TODAY" +%u); TOFF=$(( (TDOW - WEEK_ANCHOR_DOW + 7) % 7 ))
CWSTART=$(date -j -v-"${TOFF}"d -f %Y-%m-%d "$TODAY" +%F); CW_ELAPSED=$(( TOFF + 1 ))
CW_SPENT=$(awk -F'\t' -v w="$CWSTART" '$1==w{print $2+0;f=1} END{if(!f)print 0}' "$TMP/weeks.tsv")
CW_MSGS=$(awk -F'\t' -v w="$CWSTART" '$1==w{print $3+0;f=1} END{if(!f)print 0}' "$TMP/weeks.tsv")

read -r CW_PCT CW_EXP CW_PROJ CW_STATE CW_FILL CW_PACE CW_OVER CW_HEAD CW_PW < <(awk \
  -v s="$CW_SPENT" -v t="$WEEKLY_CEILING" -v e="$CW_ELAPSED" 'BEGIN{
  frac=e/7.0; if(frac>1)frac=1; xp=t*frac; proj=(e>0)?s/e*7:0; pct=(t>0)?s/t*100:0;
  fill=(pct>100)?100:pct; pace=frac*100; st=(s>t)?"over":((proj>t)?"near":"under");
  over=(s>t)?s-t:0; head=(proj<t)?t-proj:0;
  pf=(t>0)?proj/t*100:0; if(pf>100)pf=100; pw=pf-fill; if(pw<0)pw=0;
  printf "%.0f %.0f %.0f %s %.1f %.1f %.0f %.0f %.1f", pct,xp,proj,st,fill,pace,over,head,pw }')

case "$CW_STATE" in
  over)  CW_MSG="over target by $(money "$CW_OVER") · projected $(money "$CW_PROJ")";;
  near)  CW_MSG="projected $(money "$CW_PROJ") · over the $(money "$WEEKLY_CEILING") target at this pace";;
  *)     CW_MSG="under target · projected $(money "$CW_PROJ") · $(money "$CW_HEAD") headroom";;
esac

# previous-weeks bullet bars (exclude current week), newest first
PWEEKS=$(awk -F'\t' "$AWKLIB"'$1!=cur{
    split($1,d,"-"); lab=(d[2]+0)"/"(d[3]+0);
    pct=(t>0)?$2/t*100:0; fillpct=(pct>100)?100:pct;
    if($2>t){st="over";rc="ov";rt=sprintf("over $%s",grp($2-t,0))}
    else{st="under";rc="lf";rt=sprintf("$%s left",grp(t-$2,0))}
    printf "%s\t<div class=\"pwrow\"><div class=\"pwlab\">wk %s</div><div class=\"pwtrack\"><div class=\"pwfill %s\" style=\"width:%.1f%%\"></div><div class=\"pwtgt\"></div></div><div class=\"pwval\">$%s</div><div class=\"pwleft %s\">%s</div></div>\n",
      $1,lab,st,fillpct,grp($2,0),rc,rt }' cur="$CWSTART" t="$WEEKLY_CEILING" "$TMP/weeks.tsv" \
  | sort -t$'\t' -k1,1 -r | head -8 | cut -f2-)

read -r LEFT_TOT AVG_UTIL PWK_N < <(awk -F'\t' -v cur="$CWSTART" -v t="$WEEKLY_CEILING" \
  '$1!=cur{n++;tot+=$2;if($2<t)left+=t-$2} END{printf "%.0f %.0f %d",left+0,(n>0?tot/n/t*100:0),n+0}' "$TMP/weeks.tsv")

# ---- bang for buck: work per proxy-$ (msgs/$, output-tok/$, all-tok/$) -----
# archive cols: date(1) proj(2) model(3) msgs(4) inp(5) out(6) cr(7) cc(8)
BYMODEL=$(awk -F'\t' "$AWKLIB"'valid($1){cost=w($3,$5,$6,$7,$8);k=$3;
    c[k]+=cost;m[k]+=$4;o[k]+=$6;t[k]+=$5+$6+$7+$8}
  END{for(k in c){if(c[k]<0.01)continue;mp=m[k]/c[k];
    printf "%.4f\t<div class=\"erow\"><span class=\"en\">%s</span><span>%s</span><span>%s</span><span>%s</span><span class=\"ec\">$%s</span></div>\n",
      mp,mname(k),kfmt(mp),kfmt(o[k]/c[k]),kfmt(t[k]/c[k]),grp(c[k],0)}}' "$ARCHIVE" \
  | sort -t$'\t' -k1,1 -rn | cut -f2-)
BYPROJ_E=$(awk -F'\t' "$AWKLIB"'valid($1){cost=w($3,$5,$6,$7,$8);k=$2;
    c[k]+=cost;m[k]+=$4;o[k]+=$6;t[k]+=$5+$6+$7+$8}
  END{for(k in c){if(c[k]<2)continue;mp=m[k]/c[k];
    printf "%.4f\t<div class=\"erow\"><span class=\"en\" title=\"%s\">%s</span><span>%s</span><span>%s</span><span>%s</span><span class=\"ec\">$%s</span></div>\n",
      mp,k,k,kfmt(mp),kfmt(o[k]/c[k]),kfmt(t[k]/c[k]),grp(c[k],0)}}' "$ARCHIVE" \
  | sort -t$'\t' -k1,1 -rn | head -8 | cut -f2-)
BYDAY_E=$(awk -F'\t' "$AWKLIB"'valid($1)&&$1>=cut{cost=w($3,$5,$6,$7,$8);k=$1;
    c[k]+=cost;m[k]+=$4;o[k]+=$6;t[k]+=$5+$6+$7+$8}
  END{for(k in c){if(c[k]<0.01)continue;mp=m[k]/c[k];split(k,d,"-");
    printf "%s\t<div class=\"erow\"><span class=\"en\">%s</span><span>%s</span><span>%s</span><span>%s</span><span class=\"ec\">$%s</span></div>\n",
      k,(d[2]+0)"/"(d[3]+0),kfmt(mp),kfmt(o[k]/c[k]),kfmt(t[k]/c[k]),grp(c[k],0)}}' cut="$CUT14" "$ARCHIVE" \
  | sort -t$'\t' -k1,1 -r | cut -f2-)

GEN="$(date '+%a %b %-d, %-I:%M %p')"

cat > "$OUT" <<HTML
<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Claude Usage — $TODAY</title>
<style>
:root{--bg:#0f1115;--panel:#171a21;--panel2:#1d212b;--tx:#e6e8eb;--mut:#8b929e;--grid:#262b36;
--accent:#4f8cff;--hot:#ff5c5c;--ok:#34d399;--opus:#a855f7;--fable:#ec4899;--sonnet:#38bdf8;--haiku:#34d399}
@media(prefers-color-scheme:light){:root{--bg:#f5f6f8;--panel:#fff;--panel2:#eef1f4;--tx:#1a1d23;--mut:#5b6472;--grid:#e3e6eb}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--tx);
font:14px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",system-ui,sans-serif}
.wrap{max-width:1060px;margin:0 auto;padding:28px 20px 60px}
h1{font-size:20px;margin:0 0 2px;font-weight:650;letter-spacing:-.01em}
.sub{color:var(--mut);font-size:12.5px;margin-bottom:22px}
.badge{display:inline-block;padding:3px 11px;border-radius:20px;font-size:12px;font-weight:600;vertical-align:middle;margin-left:8px}
.badge.ok{background:rgba(52,211,153,.15);color:var(--ok)} .badge.hot{background:rgba(255,92,92,.16);color:var(--hot)}
.lbl{font-size:11px;text-transform:uppercase;letter-spacing:.06em;color:var(--mut);margin:0 0 10px;font-weight:600}
.cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(200px,1fr));gap:12px;margin-bottom:26px}
.card{background:var(--panel);border:1px solid var(--grid);border-radius:12px;padding:15px 16px}
.card .k{color:var(--mut);font-size:11.5px;text-transform:uppercase;letter-spacing:.05em}
.card .v{font-size:26px;font-weight:680;margin-top:5px;font-variant-numeric:tabular-nums}
.card .n{color:var(--mut);font-size:11.5px;margin-top:3px} .card .v.hot{color:var(--hot)}
.card .nm{color:var(--mut);font-size:11.5px;margin-top:1px;font-variant-numeric:tabular-nums;opacity:.85}
.banner{display:flex;flex-wrap:wrap;align-items:baseline;gap:9px;background:var(--panel);border:1px solid var(--grid);border-radius:12px;padding:13px 18px;margin-bottom:22px;font-variant-numeric:tabular-nums}
.banner .bk{font-size:11px;text-transform:uppercase;letter-spacing:.06em;color:var(--mut);font-weight:600}
.banner b{font-size:19px;font-weight:700}
.banner .bu{color:var(--mut);font-size:12.5px;margin-left:-3px}
.banner .bx{color:var(--mut);opacity:.4} .banner .br{color:var(--mut);font-size:12.5px;margin-left:auto}
.ptot{display:flex;align-items:center;gap:9px;border-top:2px solid var(--grid);margin-top:6px;padding-top:12px;font-weight:680;font-size:14px}
.ptot .ptn{margin-left:auto;color:var(--mut);font-size:11.5px;font-weight:400;font-variant-numeric:tabular-nums}
.ptot .ptc{font-variant-numeric:tabular-nums;font-weight:680;min-width:70px;text-align:right}
.lrow.ltot{border-top:2px solid var(--grid);margin-top:6px;padding-top:11px;font-weight:700}
.lrow.ltot .lname{font-weight:700} .lrow.ltot .ltrack{visibility:hidden}
.panel{background:var(--panel);border:1px solid var(--grid);border-radius:14px;padding:18px 20px;margin-bottom:20px}
.panel h2{font-size:13px;text-transform:uppercase;letter-spacing:.05em;color:var(--mut);margin:0 0 6px;font-weight:600}
.panel .cap{color:var(--mut);font-size:12px;margin:0 0 20px;font-variant-numeric:tabular-nums}
.chart{position:relative;height:212px;display:flex;align-items:flex-end;gap:3px;border-bottom:1px solid var(--grid);padding-bottom:0}
.col{flex:1;display:flex;flex-direction:column;align-items:center;justify-content:flex-end;height:100%;position:relative}
.bar{width:80%;background:linear-gradient(180deg,var(--accent),#3b6fd4);border-radius:3px 3px 0 0}
.bar.hot{background:linear-gradient(180deg,var(--hot),#c93b3b)}
.bar:hover{opacity:.72;cursor:pointer}
.bar.sel{opacity:1;box-shadow:0 0 0 2px var(--bg),0 0 0 4px var(--tx)}
.readout{margin-top:26px;font-size:13.5px;color:var(--tx);min-height:20px;font-variant-numeric:tabular-nums}
.readout .rohint{color:var(--mut)} .readout .roc{color:var(--accent);font-weight:700} .readout .roc.hot{color:var(--hot)}
.lrow{display:flex;align-items:center;gap:11px;padding:6px 0}
.lname{width:32%;font-size:12.5px;font-weight:550;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.ltrack{flex:1;background:var(--panel2);height:7px;border-radius:4px;overflow:hidden}
.lbar{height:100%;background:linear-gradient(90deg,var(--accent),#7b6cf0)}
.lmsg{color:var(--mut);font-size:11px;font-variant-numeric:tabular-nums;width:84px;text-align:right}
.lcost{width:70px;text-align:right;font-variant-numeric:tabular-nums;font-weight:650;font-size:13px}
@media(max-width:560px){.lname{width:40%}.lmsg{display:none}}
.xl{position:absolute;bottom:-18px;font-size:9.5px;color:var(--mut);white-space:nowrap}
.xl.hotl{color:var(--hot);font-weight:700}
.thr{position:absolute;left:0;right:0;border-top:1px dashed var(--hot);opacity:.45}
.thrlab{position:absolute;left:2px;font-size:10px;color:var(--hot);opacity:.85;transform:translateY(-14px);background:var(--panel);padding:0 4px}
.legend{display:flex;flex-wrap:wrap;gap:16px;margin-top:30px;font-size:12px;color:var(--mut)}
.legend .sw{display:inline-block;width:10px;height:10px;border-radius:3px;margin-right:6px;vertical-align:middle}
.stack{display:flex;height:34px;border-radius:8px;overflow:hidden;margin-bottom:14px}
.s-op{background:var(--opus)} .s-fa{background:var(--fable)} .s-so{background:var(--sonnet)} .s-ha{background:var(--haiku)}
.mleg{display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:10px}
.mrow{display:flex;align-items:center;gap:8px;font-size:12.5px}
.mrow .sw{width:11px;height:11px;border-radius:3px} .mrow b{font-variant-numeric:tabular-nums} .mrow .mp{color:var(--mut);margin-left:auto;font-variant-numeric:tabular-nums}
.pcard{padding:14px 0;border-top:1px solid var(--grid)} .pcard:first-child{border-top:0}
.pl1{display:flex;align-items:center;gap:9px;margin-bottom:8px}
.pname{font-weight:600;font-size:14px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;max-width:58%}
.pcost{margin-left:auto;font-variant-numeric:tabular-nums;font-weight:650}
.flag{font-size:10px;font-weight:600;color:var(--hot);background:rgba(255,92,92,.14);padding:2px 7px;border-radius:20px}
.pbarwrap{height:15px;border-radius:5px;overflow:hidden;margin-bottom:8px;min-width:3px;background:var(--panel2)}
.pbarwrap .mmini{display:flex;height:100%;width:100%} .pbarwrap .mmini>div{min-width:0}
.mmini>div:hover{filter:brightness(1.15)}
.pl3{font-size:11.5px;color:var(--mut);font-variant-numeric:tabular-nums}
.pl3 .o{color:var(--opus)} .pl3 .f{color:var(--fable)} .pl3 .s{color:var(--sonnet)} .pl3 .h{color:var(--haiku)}
.pl3 .cr.hicr{color:var(--hot);font-weight:600}
.wktop{display:flex;align-items:baseline;gap:10px;margin:2px 0 9px;font-size:14px}
.wkstate{font-size:12.5px;font-weight:600}
.wkstate.under,.pwleft.lf{color:var(--ok)} .wkstate.over,.pwleft.ov{color:var(--hot)} .wkstate.near{color:#e0a400}
.wkbar{position:relative;height:26px;background:var(--panel2);border-radius:8px;overflow:hidden}
.wkfill{height:100%;background:linear-gradient(90deg,var(--ok),#2fa37a);min-width:2px}
.wkfill.near{background:linear-gradient(90deg,#f5b301,#d99a00)}
.wkfill.over{background:linear-gradient(90deg,var(--hot),#c93b3b)}
.wkproj{position:absolute;top:0;bottom:0;opacity:.5;background:repeating-linear-gradient(45deg,var(--ok) 0,var(--ok) 3px,transparent 3px,transparent 8px)}
.wkproj.near{background:repeating-linear-gradient(45deg,#e0a400 0,#e0a400 3px,transparent 3px,transparent 8px)}
.wkproj.over{background:repeating-linear-gradient(45deg,var(--hot) 0,var(--hot) 3px,transparent 3px,transparent 8px)}
.wksub{color:var(--mut);font-size:12px;margin-top:8px;font-variant-numeric:tabular-nums}
.pwrow{display:grid;grid-template-columns:52px 1fr 66px 96px;gap:10px;align-items:center;padding:5px 0;font-size:12px;font-variant-numeric:tabular-nums}
.pwlab{color:var(--mut)}
.pwtrack{position:relative;height:12px;background:var(--panel2);border-radius:4px;overflow:hidden}
.pwfill{height:100%} .pwfill.under{background:var(--ok)} .pwfill.over{background:var(--hot)}
.pwtgt{position:absolute;right:0;top:0;bottom:0;width:2px;background:var(--tx);opacity:.35}
.pwval{text-align:right;font-weight:650} .pwleft{text-align:right}
.pwsum{color:var(--mut);font-size:12px;margin-top:12px} .pwsum b{color:var(--tx)}
@media(max-width:560px){.pwrow{grid-template-columns:46px 1fr 58px 84px;gap:7px}}
.effgrid{display:grid;grid-template-columns:1fr 1fr;gap:24px;margin-bottom:2px}
@media(max-width:720px){.effgrid{grid-template-columns:1fr;gap:8px}}
.effh{font-size:10.5px;text-transform:uppercase;letter-spacing:.05em;color:var(--mut);margin:4px 0 8px;font-weight:600}
.etbl{font-variant-numeric:tabular-nums;font-size:12px;margin-bottom:14px}
.ehead,.erow{display:grid;grid-template-columns:1.5fr .82fr .82fr .82fr .96fr;gap:8px;align-items:center}
.ehead{font-size:9.5px;text-transform:uppercase;letter-spacing:.03em;color:var(--mut);padding-bottom:6px;border-bottom:1px solid var(--grid)}
.ehead span:not(:first-child),.erow span:not(:first-child){text-align:right}
.erow{padding:5px 0;border-bottom:1px solid var(--grid)} .erow:last-child{border-bottom:0}
.erow .en{font-weight:550;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.erow .ec{color:var(--mut)}
.foot{color:var(--mut);font-size:11.5px;margin-top:8px;line-height:1.6}
@media(max-width:560px){.pname{max-width:44%}}
</style></head><body><div class="wrap">
<h1>Claude Code Usage <span class="badge $SCLASS">$STATUS</span></h1>
<div class="sub">Generated $GEN · cost-weighted proxy (list prices), relative to your own baseline — not your real plan quota</div>

<div class="banner"><span class="bk">Grand total</span><b>$(money "$T_ALL")</b><span class="bu">spend</span><span class="bx">·</span><b>$(comma "$N_ALL")</b><span class="bu">messages</span><span class="br">$RANGE_LABEL · $NDAYS days logged</span></div>

<div class="lbl">Spend totals (proxy)</div>
<div class="cards">
  <div class="card"><div class="k">Today</div><div class="v $([ "$SCLASS" = hot ] && echo hot)">$(money "$T_DAY")</div><div class="n">$TODAY</div><div class="nm">$(comma "$N_DAY") msgs</div></div>
  <div class="card"><div class="k">This week (7d)</div><div class="v $([ "$WEEKPCT" -ge 100 ] && echo hot)">$(money "$T_WEEK")</div><div class="n">${WEEKPCT}% of $(money "$WEEKLY_CEILING") ceiling</div><div class="nm">$(comma "$N_WEEK") msgs</div></div>
  <div class="card"><div class="k">This month</div><div class="v">$(money "$T_MONTH")</div><div class="n">$MONTH_LABEL</div><div class="nm">$(comma "$N_MONTH") msgs</div></div>
  <div class="card"><div class="k">All time</div><div class="v">$(money "$T_ALL")</div><div class="n">$EARLY_LABEL</div><div class="nm">$(comma "$N_ALL") msgs</div></div>
</div>

<div class="panel"><h2>Weekly budget — target &amp; pacing</h2>
<div class="cap">target $(money "$WEEKLY_CEILING")/wk · weeks reset $ANCHORNAME · solid = spent so far · striped = projected spend by end of week · the bar's full width is the target · proxy \$ (tune with SENTINEL_WEEKLY_CEILING / reset day with USAGE_WEEK_ANCHOR_DOW)</div>
<div class="wktop"><b>This week</b><span class="wkstate $CW_STATE">$CW_MSG</span></div>
<div class="wkbar"><div class="wkfill $CW_STATE" style="width:${CW_FILL}%"></div><div class="wkproj $CW_STATE" style="left:${CW_FILL}%;width:${CW_PW}%" title="at this pace &#8594; $(money "$CW_PROJ") by end of week"></div></div>
<div class="wksub">Day $CW_ELAPSED of 7 · spent $(money "$CW_SPENT") · projected $(money "$CW_PROJ") of $(money "$WEEKLY_CEILING") · $(comma "$CW_MSGS") msgs</div>
<div class="effh" style="margin-top:22px">Previous weeks · bar = spend vs the $(money "$WEEKLY_CEILING") target</div>
$PWEEKS
<div class="pwsum">Across $PWK_N prior weeks you averaged <b>${AVG_UTIL}%</b> of target and left <b>$(money "$LEFT_TOT")</b> on the table (unused headroom under the target).</div>
</div>

<div class="panel"><h2>Daily proxy — last $DAYS days</h2>
  <div class="cap">typical $(money "$MEDIAN")/day · anomaly line $(money "$THRESH") · peak in view $(money "$CHARTMAX") · red bars are dated</div>
  <div class="chart"><div class="thr" style="bottom:${THRPOS}px"></div><div class="thrlab" style="bottom:${THRPOS}px">${ANOMALY_FACTOR}× median</div>$DAILY_HTML</div>
  <div class="readout" id="ro"><span class="rohint">Tap or click any bar for its exact value ↑</span></div>
  <div class="legend"><span><span class="sw" style="background:var(--accent)"></span>normal day</span><span><span class="sw" style="background:var(--hot)"></span>anomaly (&gt; ${ANOMALY_FACTOR}× median)</span><span style="color:var(--mut)">hover for a quick peek · click to pin it below</span></div>
</div>

<div class="panel"><h2>Model mix — last 7 days ($(money "$M_TOT"))</h2><div class="cap">where the money goes by tier</div>
  <div class="stack"><div class="s-op" style="flex:$MP_OP" title="Opus $MF_OP"></div><div class="s-fa" style="flex:$MP_FA" title="Fable $MF_FA"></div><div class="s-so" style="flex:$MP_SO" title="Sonnet $MF_SO"></div><div class="s-ha" style="flex:$MP_HA" title="Haiku $MF_HA"></div></div>
  <div class="mleg">
    <div class="mrow"><span class="sw" style="background:var(--opus)"></span>Opus (4.8 + 5) <b>$MF_OP</b><span class="mp">${MP_OP}%</span></div>
    <div class="mrow"><span class="sw" style="background:var(--fable)"></span>Fable 5 <b>$MF_FA</b><span class="mp">${MP_FA}%</span></div>
    <div class="mrow"><span class="sw" style="background:var(--sonnet)"></span>Sonnet (5 + 4.6) <b>$MF_SO</b><span class="mp">${MP_SO}%</span></div>
    <div class="mrow"><span class="sw" style="background:var(--haiku)"></span>Haiku 4.5 <b>$MF_HA</b><span class="mp">${MP_HA}%</span></div>
  </div>
</div>

<div class="panel"><h2>Top projects — last 7 days</h2><div class="cap">bar width = spend vs the top project · colored segments = model mix (hover for \$) · cache-read flags marathon sessions</div>
$PROJ_HTML
  <div class="ptot"><span>All projects · 7 days</span><span class="ptn">$(comma "$N_WEEK") msgs</span><span class="ptc">$(money "$T_WEEK")</span></div>
</div>

<div class="panel"><h2>Lifetime by project — all time</h2><div class="cap">every project ranked by total proxy \$ since $EARLIEST · GEOFF here folds in Fieldglass + CEO Dashboard + MSL</div>
$LIFE_HTML
  <div class="lrow ltot"><div class="lname">All projects</div><div class="ltrack"></div><div class="lmsg">$(comma "$N_ALL") msgs</div><div class="lcost">$(money "$T_ALL")</div></div>
</div>

<div class="panel"><h2>Bang for buck — work per proxy-\$</h2>
<div class="cap">higher = more usage per \$ · the big lever is cache-reuse (long sessions get cheap per turn), not just which model · proxy \$, not your real quota</div>
<div class="effgrid">
  <div><div class="effh">By model · all time</div>
    <div class="etbl"><div class="ehead"><span>model</span><span>msgs/\$</span><span>out/\$</span><span>tok/\$</span><span>proxy \$</span></div>
$BYMODEL</div></div>
  <div><div class="effh">By project · all time (top 8 by msgs/\$)</div>
    <div class="etbl"><div class="ehead"><span>project</span><span>msgs/\$</span><span>out/\$</span><span>tok/\$</span><span>proxy \$</span></div>
$BYPROJ_E</div></div>
</div>
<div class="effh">By day · last 14 days (newest first)</div>
<div class="etbl"><div class="ehead"><span>day</span><span>msgs/\$</span><span>out/\$</span><span>tok/\$</span><span>proxy \$</span></div>
$BYDAY_E</div>
</div>

<div class="foot">Priced by the <b>exact model each message ran on</b> (per 1M tok): Opus 4.8/5 &amp; Fable 5 \$15 in · \$75 out · \$1.50 cache-rd · \$18.75 cache-wr; Sonnet 5/4.6 \$3/\$15/\$0.30/\$3.75; Haiku 4.5 \$0.80/\$4/\$0.08/\$1; &lt;synthetic&gt; free. Fable is seeded at Opus rates — edit the rate table atop <code>usage-dashboard.sh</code> to correct any price (history reprices automatically). <b>marathon</b> = very high cache-read over many turns (the turns×context tax). History is banked to <code>usage-history.tsv</code> each run so it outlives Claude Code's ~30-day log cleanup — the window grows from here.<br>Regenerated nightly by usage-sentinel · <code>./usage-dashboard.sh</code> to refresh now.</div>
</div>
<script>
(function(){
  var MO=["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"];
  var ro=document.getElementById('ro'), bars=document.querySelectorAll('.chart .bar');
  function money(c){ return '\$'+Math.round(+c).toLocaleString(); }
  function show(b){
    bars.forEach(function(x){x.classList.remove('sel')});
    b.classList.add('sel');
    var p=b.dataset.d.split('-'), lab=MO[(+p[1])-1]+' '+(+p[2])+', '+p[0];
    var hot=b.classList.contains('hot')?' hot':'';
    ro.innerHTML='<b>'+lab+'</b> — <span class="roc'+hot+'">'+money(b.dataset.c)+'</span> · '+(+b.dataset.m).toLocaleString()+' msgs';
  }
  bars.forEach(function(b){ b.addEventListener('click',function(){show(b)}); });
})();
</script>
</body></html>
HTML

echo "$OUT"
