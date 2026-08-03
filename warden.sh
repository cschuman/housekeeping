#!/usr/bin/env bash
# Projects Warden — the "state of the estate" engine. See ~/Projects/PROJECTS.md.
#
#   ./warden.sh              scan + print report (read-only, always safe)
#   ./warden.sh --fast       skip du sizing (quick interactive runs)
#   ./warden.sh --email      scan + email the report via gws (Monday launchd job)
#   ./warden.sh --propose    also emit a ready-to-review filing script (never runs it)
#   ./warden.sh --auto       safe ops only: regen INDEX.md, purge .DS_Store
#   ./warden.sh reclaim      list regenerable build artifacts in stale projects (dry run)
#   ./warden.sh reclaim-run  delete them (only in projects inactive 60+ days, never 'active')
#   ./warden.sh status <project> <active|incubating|done|dead|someday>
#
# Verdicts live in <project>/.warden-status (one word). Root is an inbox, not a sin:
# mkdir anywhere; the warden proposes filing later. It never moves anything itself.
set -uo pipefail

ROOT="$HOME/Projects"
WARD="$ROOT/.warden"
MANIFEST="$WARD/manifest.tsv"
REPORT="$WARD/report.md"
PROPOSALS="$WARD/proposals.sh"
EMAIL_TO="cschuman@gmail.com"
mkdir -p "$WARD"

# ---- subcommand: reclaim build artifacts from stale projects ---------------
# Regenerable only: node_modules, Rust target (Cargo.toml sibling), python venvs,
# __pycache__. Skips projects marked 'active' or with activity in the last 60 days.
if [ "${1:-}" = "reclaim" ] || [ "${1:-}" = "reclaim-run" ]; then
  RUN=0; [ "$1" = "reclaim-run" ] && RUN=1
  cutoff=$(date -v-60d +%Y-%m-%d)
  total_mb=0
  for d in "$ROOT"/*/; do
    d="${d%/}"; name="$(basename "$d")"
    case "$name" in archive|.warden) continue;; esac
    status="unfiled"; [ -f "$d/.warden-status" ] && status="$(head -1 "$d/.warden-status" | tr -d '[:space:]')"
    [ "$status" = "active" ] && continue
    act="$(git -C "$d" log -1 --format=%cs 2>/dev/null)"
    [ -z "$act" ] && act="$(stat -f %Sm -t %Y-%m-%d "$d" 2>/dev/null)"
    [ "$act" \> "$cutoff" ] && continue
    find "$d" -maxdepth 3 \( -name node_modules -o -name target -o -name .venv -o -name venv -o -name __pycache__ \) -type d -prune 2>/dev/null \
    | while read -r a; do
        base="$(basename "$a")"
        if [ "$base" = "target" ] && [ ! -f "$(dirname "$a")/Cargo.toml" ]; then continue; fi
        if [ "$base" = "venv" ] || [ "$base" = ".venv" ]; then [ -f "$a/pyvenv.cfg" ] || continue; fi
        mb=$(du -sm "$a" 2>/dev/null | cut -f1)
        if [ "$RUN" -eq 1 ]; then rm -rf "$a" && printf 'freed %5s MB  %s\n' "$mb" "${a#$ROOT/}"
        else printf '%5s MB  %s (last activity %s)\n' "$mb" "${a#$ROOT/}" "$act"; fi
      done
  done | sort -rn
  [ "$RUN" -eq 0 ] && echo "(dry run — delete with: warden.sh reclaim-run)"
  exit 0
fi

# ---- subcommand: set a status verdict -------------------------------------
if [ "${1:-}" = "status" ]; then
  proj="$ROOT/${2:?usage: warden.sh status <project> <verdict>}"
  verdict="${3:?verdict: active|incubating|done|dead|someday}"
  case "$verdict" in active|incubating|done|dead|someday|evergreen) ;; *)
    echo "invalid verdict '$verdict' (active|incubating|done|dead|someday|evergreen)"; exit 1;; esac
  [ -d "$proj" ] || { echo "no such project: $proj"; exit 1; }
  echo "$verdict" > "$proj/.warden-status"
  echo "$(basename "$proj") → $verdict"
  exit 0
fi

FAST=0; EMAIL=0; PROPOSE=0; AUTO=0
for a in "$@"; do case "$a" in
  --fast) FAST=1;; --email) EMAIL=1;; --propose) PROPOSE=1;; --auto) AUTO=1;;
esac; done

# ---- scan -----------------------------------------------------------------
# manifest: name  status  vcs  dirty  remote  last_commit  mtime  size_mb
: > "$MANIFEST"
for d in "$ROOT"/*/; do
  d="${d%/}"; name="$(basename "$d")"
  case "$name" in archive|.warden) continue;; esac
  status="unfiled"; [ -f "$d/.warden-status" ] && status="$(head -1 "$d/.warden-status" | tr -d '[:space:]')"
  vcs="none"; dirty="-"; remote="-"; last_commit="-"
  if [ -d "$d/.git" ]; then
    vcs="git"
    if [ -n "$(git -C "$d" status --porcelain 2>/dev/null | head -1)" ]; then dirty="dirty"; else dirty="clean"; fi
    [ -n "$(git -C "$d" remote 2>/dev/null | head -1)" ] && remote="yes" || remote="no"
    last_commit="$(git -C "$d" log -1 --format=%cs 2>/dev/null || echo '-')"
  fi
  mtime="$(stat -f %Sm -t %Y-%m-%d "$d" 2>/dev/null || echo '-')"
  size_mb="-"
  [ "$FAST" -eq 0 ] && size_mb="$(du -sk -x "$d" 2>/dev/null | awk '{printf "%d", $1/1024}')"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$name" "$status" "$vcs" "$dirty" "$remote" "$last_commit" "$mtime" "$size_mb" >> "$MANIFEST"
done

# archive scan (for INDEX + counts only)
ARCHIVED=0
if [ -d "$ROOT/archive" ]; then
  ARCHIVED=$(find "$ROOT/archive" -mindepth 2 -maxdepth 2 -type d 2>/dev/null | wc -l | tr -d ' ')
fi

# ---- derive ---------------------------------------------------------------
total=$(wc -l < "$MANIFEST" | tr -d ' ')
no_vcs=$(awk -F'\t' '$3=="none"' "$MANIFEST" | wc -l | tr -d ' ')
no_remote=$(awk -F'\t' '$3=="git" && $5=="no"' "$MANIFEST" | wc -l | tr -d ' ')
dirty_n=$(awk -F'\t' '$4=="dirty"' "$MANIFEST" | wc -l | tr -d ' ')
unfiled=$(awk -F'\t' '$2=="unfiled"' "$MANIFEST" | wc -l | tr -d ' ')
done_n=$(awk -F'\t' '$2=="done"' "$MANIFEST" | wc -l | tr -d ' ')
dead_n=$(awk -F'\t' '$2=="dead"' "$MANIFEST" | wc -l | tr -d ' ')
active_n=$(awk -F'\t' '$2=="active"' "$MANIFEST" | wc -l | tr -d ' ')

# ---- report ---------------------------------------------------------------
{
  echo "# State of the Estate — $(date '+%Y-%m-%d')"
  echo
  echo "**$total** projects at root · **$active_n** active · **$((done_n+dead_n))** shipped-or-retired (nice) · **$ARCHIVED** archived · **$unfiled** awaiting a verdict"
  echo
  echo "## ⚠ Backup risk (the only irreversible problem)"
  echo
  echo "Not a git repo at all ($no_vcs):"
  awk -F'\t' '$3=="none" {printf "- %s (touched %s)\n", $1, $7}' "$MANIFEST" | head -15
  [ "$no_vcs" -gt 15 ] && echo "- …and $((no_vcs-15)) more (see manifest)"
  echo
  echo "Git but no remote ($no_remote):"
  awk -F'\t' '$3=="git" && $5=="no" {printf "- %s (last commit %s)\n", $1, $6}' "$MANIFEST" | head -15
  echo
  echo "## Uncommitted work ($dirty_n repos)"
  echo
  awk -F'\t' '$4=="dirty" {printf "- %s (last commit %s)\n", $1, $6}' "$MANIFEST" | sort -t'(' -k2
  echo
  echo "## This week's three actions"
  echo
  n=1
  if [ "$no_vcs" -gt 0 ]; then
    pick=$(awk -F'\t' '$3=="none"' "$MANIFEST" | sort -t$'\t' -k7 -r | head -1 | cut -f1)
    echo "$n. \`git init\` + push a remote for **$pick** (most recently touched non-repo)."; n=$((n+1))
  fi
  if [ "$dirty_n" -gt 0 ]; then
    pick=$(awk -F'\t' '$4=="dirty"' "$MANIFEST" | sort -t$'\t' -k6 | head -1 | cut -f1)
    echo "$n. Commit or stash **$pick** (dirty the longest)."; n=$((n+1))
  fi
  if [ "$unfiled" -gt 0 ] && [ "$n" -le 3 ]; then
    picks=$(awk -F'\t' '$2=="unfiled"' "$MANIFEST" | head -3 | cut -f1 | paste -sd, - | sed 's/,/, /g')
    echo "$n. Give a verdict to: $picks — \`warden.sh status <name> <verdict>\`"; n=$((n+1))
  fi
  [ "$n" -eq 1 ] && echo "1. Nothing urgent. The estate is healthy."
  if [ "$FAST" -eq 0 ]; then
    echo
    echo "## Disk (top 8)"
    echo
    sort -t$'\t' -k8 -rn "$MANIFEST" | head -8 | awk -F'\t' '{printf "- %s MB — %s\n", $8, $1}'
  fi
} > "$REPORT"

# ---- description truncation ------------------------------------------------
# Reads one line on stdin, emits at most $1 grapheme clusters (+ … if it cut).
# Not `cut -c`: on macOS that counts BYTES, so a 90-byte slice landed inside the
# 🇺🇸 in wc-companion's README and left a dangling \xf0\x9f\x87 that made the whole
# of INDEX.md undecodable. \X is one user-perceived character, so a flag emoji
# (two regional indicators) survives or is dropped whole. Decoding with
# FB_DEFAULT means a README that is already bad UTF-8 yields U+FFFD here rather
# than leaking its bytes into INDEX.md.
trunc_about() {
  perl -e '
    use strict; use warnings;
    use Encode qw(decode encode);
    my $n = shift;
    my $l = <STDIN>;
    exit 0 unless defined $l;
    $l = decode("UTF-8", $l, Encode::FB_DEFAULT);
    $l =~ s/\s+\z//;
    $l =~ /^(\X{0,$n})(\X?)/ or exit 0;
    print encode("UTF-8", length($2) ? "$1\x{2026}" : $1);
  ' "$1"
}

# ---- INDEX.md (object-permanence prosthetic; warden-generated, never hand-edit) ----
{
  echo "# Projects Index"
  echo
  echo "Generated by \`housekeeping/warden.sh\` — do not hand-edit. Verdict via \`warden.sh status <name> <verdict>\`."
  echo
  echo "| Project | Status | Git | Last activity | About |"
  echo "|---|---|---|---|---|"
  while IFS=$'\t' read -r name status vcs dirty remote last_commit mtime size; do
    about=""
    for r in "$ROOT/$name/README.md" "$ROOT/$name/readme.md"; do
      [ -f "$r" ] && { about="$(grep -v '^#' "$r" | grep -m1 . | trunc_about 90)"; break; }
    done
    act="$last_commit"; [ "$act" = "-" ] && act="$mtime"
    g="$vcs"; [ "$dirty" = "dirty" ] && g="git (dirty)"; [ "$remote" = "no" ] && g="$g, no remote"
    printf '| %s | %s | %s | %s | %s |\n' "$name" "$status" "$g" "$act" "${about//|/ }"
  done < "$MANIFEST"
  if [ -d "$ROOT/archive" ]; then
    echo
    echo "## Archived"
    echo
    find "$ROOT/archive" -mindepth 2 -maxdepth 2 -type d 2>/dev/null | sort | while read -r a; do
      yr="$(basename "$(dirname "$a")")"; nm="$(basename "$a")"
      about=""; [ -f "$a/README.md" ] && about="$(grep -v '^#' "$a/README.md" | grep -m1 . | trunc_about 90)"
      echo "- **$nm** ($yr) — $about"
    done
  fi
} > "$ROOT/INDEX.md"

# ---- JSON string escaping (shared by dashboard.html) -----------------------
# Same UTF-8-safety story as trunc_about: decode leniently so bad bytes don't
# leak, then escape backslash/quote/control chars and "</" so embedded
# project descriptions can never break out of the <script type=application/json>
# block they're printed into.
json_str() {
  perl -e '
    use strict; use warnings;
    use Encode qw(decode encode);
    my $s = shift;
    $s = "" unless defined $s;
    $s = decode("UTF-8", $s, Encode::FB_DEFAULT);
    $s =~ s/([\\"])/\\$1/g;
    $s =~ s{(</)}{<\\/}g;
    $s =~ s/([\x00-\x1f])/sprintf("\\u%04x", ord($1))/ge;
    print "\"", encode("UTF-8", $s), "\"";
  ' "$1"
}

# ---- dashboard.html (object-permanence prosthetic, browsable) --------------
DASH="$ROOT/dashboard.html"

# Same "this week's actions" logic as report.md above, kept in plain text
# (no markdown) since this feeds JSON/textContent, not a markdown renderer.
DASH_ACTIONS=()
if [ "$no_vcs" -gt 0 ]; then
  pick=$(awk -F'\t' '$3=="none"' "$MANIFEST" | sort -t$'\t' -k7 -r | head -1 | cut -f1)
  DASH_ACTIONS+=("git init + push a remote for $pick (most recently touched non-repo)")
fi
if [ "$dirty_n" -gt 0 ]; then
  pick=$(awk -F'\t' '$4=="dirty"' "$MANIFEST" | sort -t$'\t' -k6 | head -1 | cut -f1)
  DASH_ACTIONS+=("Commit or stash $pick (dirty the longest)")
fi
if [ "$unfiled" -gt 0 ] && [ "${#DASH_ACTIONS[@]}" -lt 3 ]; then
  picks=$(awk -F'\t' '$2=="unfiled"' "$MANIFEST" | head -3 | cut -f1 | paste -sd, - | sed 's/,/, /g')
  DASH_ACTIONS+=("Give a verdict to: $picks — warden.sh status <name> <verdict>")
fi
[ "${#DASH_ACTIONS[@]}" -eq 0 ] && DASH_ACTIONS+=("Nothing urgent. The estate is healthy.")

{
  cat <<'HTML_HEAD'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>State of the Estate</title>
<style>
  :root {
    --bg:#f7f7f8; --fg:#1a1a1e; --muted:#6b6b76; --card:#ffffff; --border:#e2e2e6;
    --green:#15803d; --amber:#b45309; --red:#b91c1c; --blue:#1d4ed8;
    --teal:#0f766e; --gray:#57534e; --slate:#475569; --badge-bg:#eef0f4;
  }
  @media (prefers-color-scheme: dark) {
    :root { --bg:#111114; --fg:#e6e6ea; --muted:#9a9aa4; --card:#1a1a1f; --border:#2c2c33; --badge-bg:#24242b; }
  }
  * { box-sizing:border-box; }
  body { margin:0; background:var(--bg); color:var(--fg); font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif; }
  #app { max-width:1200px; margin:0 auto; padding:32px 20px 80px; }
  h1 { font-size:22px; margin:0 0 4px; }
  .subtitle { color:var(--muted); font-size:13px; margin-bottom:24px; }
  .stats { display:grid; grid-template-columns:repeat(auto-fit,minmax(120px,1fr)); gap:10px; margin-bottom:20px; }
  .stat { background:var(--card); border:1px solid var(--border); border-radius:10px; padding:12px 14px; }
  .stat .n { font-size:22px; font-weight:600; }
  .stat .l { font-size:12px; color:var(--muted); }
  .stat.risk .n { color:var(--red); }
  .actions { background:var(--card); border:1px solid var(--border); border-radius:10px; padding:14px 18px; margin-bottom:24px; }
  .actions h2 { font-size:13px; text-transform:uppercase; letter-spacing:.04em; color:var(--muted); margin:0 0 8px; }
  .actions ol { margin:0; padding-left:18px; font-size:14px; line-height:1.6; }
  .controls { display:flex; gap:10px; flex-wrap:wrap; margin-bottom:12px; }
  .controls input[type=text], .controls select { background:var(--card); border:1px solid var(--border); color:var(--fg); border-radius:8px; padding:7px 10px; font-size:13px; }
  .controls input[type=text] { flex:1; min-width:180px; }
  .controls label { display:flex; align-items:center; gap:6px; font-size:13px; color:var(--muted); }
  table { width:100%; border-collapse:collapse; background:var(--card); border:1px solid var(--border); border-radius:10px; overflow:hidden; font-size:13px; }
  thead th { text-align:left; padding:9px 12px; border-bottom:1px solid var(--border); color:var(--muted); font-weight:600; cursor:pointer; user-select:none; white-space:nowrap; }
  thead th:hover { color:var(--fg); }
  tbody td { padding:9px 12px; border-bottom:1px solid var(--border); vertical-align:top; }
  tbody tr:last-child td { border-bottom:none; }
  tbody tr.risk { box-shadow: inset 3px 0 0 var(--red); }
  tbody tr.dirty { box-shadow: inset 3px 0 0 var(--amber); }
  .about { color:var(--muted); max-width:420px; }
  .badge { display:inline-block; padding:2px 8px; border-radius:999px; font-size:11px; font-weight:600; background:var(--badge-bg); }
  .badge.active{color:var(--green)} .badge.incubating{color:var(--blue)} .badge.evergreen{color:var(--teal)}
  .badge.someday{color:var(--gray)} .badge.unfiled{color:var(--amber)} .badge.done{color:var(--slate)} .badge.dead{color:var(--red)}
  .gittag { font-size:11px; color:var(--muted); font-family:ui-monospace,Menlo,monospace; }
  .gittag.warn { color:var(--amber); }
  .gittag.none { color:var(--red); }
  details.archive { margin-top:24px; }
  summary { cursor:pointer; font-size:14px; color:var(--muted); padding:8px 0; }
  .arch-list { font-size:13px; line-height:1.9; }
  .arch-list b { color:var(--fg); }
  footer { margin-top:32px; font-size:12px; color:var(--muted); line-height:1.7; }
  code { font-family:ui-monospace,Menlo,monospace; background:var(--badge-bg); padding:1px 5px; border-radius:4px; }
  .empty { color:var(--muted); padding:20px; text-align:center; }
</style>
</head>
<body>
<div id="app">
  <h1>State of the Estate</h1>
  <div class="subtitle" id="subtitle"></div>
  <div class="stats" id="stats"></div>
  <div class="actions"><h2>This week</h2><ol id="actions"></ol></div>
  <div class="controls">
    <input type="text" id="q" placeholder="Filter by name or description…">
    <select id="statusFilter"><option value="">All statuses</option></select>
    <label><input type="checkbox" id="riskOnly"> Backup risk only</label>
  </div>
  <table>
    <thead><tr>
      <th data-k="name">Project</th>
      <th data-k="status">Status</th>
      <th data-k="git">Git</th>
      <th data-k="last_commit">Last activity</th>
      <th data-k="size_mb">Size</th>
      <th data-k="about">About</th>
    </tr></thead>
    <tbody id="rows"></tbody>
  </table>
  <details class="archive"><summary id="archSummary">Archived</summary><div class="arch-list" id="archList"></div></details>
  <footer id="footer"></footer>
</div>
<script id="warden-data" type="application/json">
HTML_HEAD

  printf '{'
  printf '"generated":%s,' "$(json_str "$(date '+%Y-%m-%d %H:%M')")"
  printf '"stats":{"total":%s,"active":%s,"unfiled":%s,"archived":%s,"no_vcs":%s,"no_remote":%s,"dirty":%s,"done":%s,"dead":%s},' \
    "$total" "$active_n" "$unfiled" "$ARCHIVED" "$no_vcs" "$no_remote" "$dirty_n" "$done_n" "$dead_n"
  printf '"actions":['
  first=1
  for act in "${DASH_ACTIONS[@]}"; do
    [ "$first" -eq 1 ] || printf ','
    json_str "$act"
    first=0
  done
  printf '],'
  printf '"projects":['
  first=1
  while IFS=$'\t' read -r name status vcs dirty remote last_commit mtime size; do
    about=""
    for r in "$ROOT/$name/README.md" "$ROOT/$name/readme.md"; do
      [ -f "$r" ] && { about="$(grep -v '^#' "$r" | grep -m1 . | trunc_about 200)"; break; }
    done
    [ "$first" -eq 1 ] || printf ','
    printf '{"name":%s,"status":%s,"vcs":%s,"dirty":%s,"remote":%s,"last_commit":%s,"mtime":%s,"size_mb":%s,"about":%s}' \
      "$(json_str "$name")" "$(json_str "$status")" "$(json_str "$vcs")" "$(json_str "$dirty")" \
      "$(json_str "$remote")" "$(json_str "$last_commit")" "$(json_str "$mtime")" "$(json_str "$size")" "$(json_str "$about")"
    first=0
  done < "$MANIFEST"
  printf '],'
  printf '"archived":['
  first=1
  if [ -d "$ROOT/archive" ]; then
    while read -r a; do
      yr="$(basename "$(dirname "$a")")"; nm="$(basename "$a")"
      about=""; [ -f "$a/README.md" ] && about="$(grep -v '^#' "$a/README.md" | grep -m1 . | trunc_about 200)"
      [ "$first" -eq 1 ] || printf ','
      printf '{"name":%s,"year":%s,"about":%s}' "$(json_str "$nm")" "$(json_str "$yr")" "$(json_str "$about")"
      first=0
    done < <(find "$ROOT/archive" -mindepth 2 -maxdepth 2 -type d 2>/dev/null | sort)
  fi
  printf ']'
  printf '}'

  cat <<'HTML_TAIL'
</script>
<script>
(function(){
  var data = JSON.parse(document.getElementById('warden-data').textContent);
  var $ = function(id){ return document.getElementById(id); };

  $('subtitle').textContent = 'Generated ' + data.generated + ' by warden.sh — regenerate with `warden.sh` (Mondays ~7:45am via launchd)';

  var stats = [
    ['Total', data.stats.total, false],
    ['Active', data.stats.active, false],
    ['Unfiled', data.stats.unfiled, false],
    ['Archived', data.stats.archived, false],
    ['No git', data.stats.no_vcs, true],
    ['No remote', data.stats.no_remote, true],
    ['Dirty', data.stats.dirty, true]
  ];
  stats.forEach(function(s){
    var d = document.createElement('div'); d.className = 'stat' + (s[2] && s[1] > 0 ? ' risk' : '');
    var n = document.createElement('div'); n.className = 'n'; n.textContent = s[1];
    var l = document.createElement('div'); l.className = 'l'; l.textContent = s[0];
    d.appendChild(n); d.appendChild(l);
    $('stats').appendChild(d);
  });

  var ol = $('actions');
  data.actions.forEach(function(a){
    var li = document.createElement('li'); li.textContent = a; ol.appendChild(li);
  });

  var statuses = Array.from(new Set(data.projects.map(function(p){ return p.status; }))).sort();
  statuses.forEach(function(s){
    var o = document.createElement('option'); o.value = s; o.textContent = s;
    $('statusFilter').appendChild(o);
  });

  function gitInfo(p) {
    if (p.vcs !== 'git') return {text:'no git', cls:'none'};
    var parts = [];
    if (p.dirty === 'dirty') parts.push('dirty');
    if (p.remote === 'no') parts.push('no remote');
    return {text: parts.length ? 'git, ' + parts.join(', ') : 'git', cls: parts.length ? 'warn' : ''};
  }

  var sortKey = 'name', sortDir = 1;

  function render() {
    var q = $('q').value.trim().toLowerCase();
    var sf = $('statusFilter').value;
    var riskOnly = $('riskOnly').checked;
    var rows = $('rows');
    rows.innerHTML = '';
    var list = data.projects.filter(function(p){
      if (sf && p.status !== sf) return false;
      if (riskOnly && !(p.vcs === 'none' || p.remote === 'no' || p.dirty === 'dirty')) return false;
      if (q && p.name.toLowerCase().indexOf(q) === -1 && p.about.toLowerCase().indexOf(q) === -1) return false;
      return true;
    });
    list.sort(function(a,b){
      var av, bv;
      if (sortKey === 'git') { av = gitInfo(a).text; bv = gitInfo(b).text; }
      else { av = a[sortKey]; bv = b[sortKey]; }
      if (sortKey === 'size_mb') {
        av = parseFloat(av); av = isNaN(av) ? -1 : av;
        bv = parseFloat(bv); bv = isNaN(bv) ? -1 : bv;
        return (av - bv) * sortDir;
      }
      return String(av || '').localeCompare(String(bv || '')) * sortDir;
    });
    if (!list.length) {
      var tr = document.createElement('tr'); var td = document.createElement('td');
      td.colSpan = 6; td.className = 'empty'; td.textContent = 'No projects match.';
      tr.appendChild(td); rows.appendChild(tr);
    }
    list.forEach(function(p){
      var tr = document.createElement('tr');
      if (p.vcs === 'none' || p.remote === 'no') tr.className = 'risk';
      else if (p.dirty === 'dirty') tr.className = 'dirty';

      var tdName = document.createElement('td'); tdName.textContent = p.name; tdName.style.fontWeight = '600';
      var tdStatus = document.createElement('td');
      var badge = document.createElement('span'); badge.className = 'badge ' + p.status; badge.textContent = p.status;
      tdStatus.appendChild(badge);
      var tdGit = document.createElement('td');
      var gi = gitInfo(p);
      var gt = document.createElement('span'); gt.className = 'gittag' + (gi.cls ? ' ' + gi.cls : ''); gt.textContent = gi.text;
      tdGit.appendChild(gt);
      var tdAct = document.createElement('td'); tdAct.textContent = (p.last_commit !== '-' ? p.last_commit : p.mtime);
      var tdSize = document.createElement('td'); tdSize.textContent = (p.size_mb === '-' ? '—' : p.size_mb + ' MB');
      var tdAbout = document.createElement('td'); tdAbout.className = 'about'; tdAbout.textContent = p.about;

      tr.appendChild(tdName); tr.appendChild(tdStatus); tr.appendChild(tdGit);
      tr.appendChild(tdAct); tr.appendChild(tdSize); tr.appendChild(tdAbout);
      rows.appendChild(tr);
    });
  }

  document.querySelectorAll('thead th').forEach(function(th){
    th.addEventListener('click', function(){
      var k = th.getAttribute('data-k');
      if (sortKey === k) sortDir *= -1; else { sortKey = k; sortDir = 1; }
      render();
    });
  });
  $('q').addEventListener('input', render);
  $('statusFilter').addEventListener('change', render);
  $('riskOnly').addEventListener('change', render);
  render();

  $('archSummary').textContent = 'Archived (' + data.archived.length + ')';
  var byYear = {};
  data.archived.forEach(function(a){ (byYear[a.year] = byYear[a.year] || []).push(a); });
  var years = Object.keys(byYear).sort().reverse();
  var archList = $('archList');
  years.forEach(function(y){
    var h = document.createElement('div');
    h.style.marginTop = '10px'; h.style.color = 'var(--muted)'; h.style.fontSize = '12px';
    h.textContent = y;
    archList.appendChild(h);
    byYear[y].forEach(function(a){
      var row = document.createElement('div');
      var b = document.createElement('b'); b.textContent = a.name;
      row.appendChild(b);
      if (a.about) row.appendChild(document.createTextNode(' — ' + a.about));
      archList.appendChild(row);
    });
  });

  var f1 = document.createElement('div'); f1.textContent = 'Source: ~/Projects/.warden/manifest.tsv, report.md, proposals.sh';
  var f2 = document.createElement('div'); f2.textContent = 'Regenerate: run warden.sh from ~/Projects/housekeeping (also runs automatically most Mondays ~7:45am).';
  $('footer').appendChild(f1); $('footer').appendChild(f2);
})();
</script>
</body>
</html>
HTML_TAIL
} > "$DASH"

# ---- proposals (never executed by the warden) -----------------------------
if [ "$PROPOSE" -eq 1 ]; then
  {
    echo "#!/usr/bin/env bash"
    echo "# Filing proposals generated $(date '+%Y-%m-%d') — REVIEW, then run by hand."
    echo "set -euo pipefail; cd \"$ROOT\"; mkdir -p archive/\$(date +%Y)"
    awk -F'\t' -v y="$(date +%Y)" '$2=="done" || $2=="dead" {printf "mv \"%s\" \"archive/%s/\"   # %s\n", $1, y, $2}' "$MANIFEST"
  } > "$PROPOSALS"
  chmod +x "$PROPOSALS"
fi

# ---- auto (safe ops only) -------------------------------------------------
if [ "$AUTO" -eq 1 ]; then
  find "$ROOT" -name .DS_Store -delete 2>/dev/null
fi

# ---- deliver --------------------------------------------------------------
if [ "$EMAIL" -eq 1 ]; then
  html="<pre style=\"font-family:ui-monospace,Menlo,monospace;font-size:13px\">$(sed 's/&/\&amp;/g;s/</\&lt;/g;s/>/\&gt;/g' "$REPORT")</pre>"
  gws gmail +send --to "$EMAIL_TO" \
    --subject "State of the Estate — $(date '+%b %d')" \
    --body "$html" --html >/dev/null 2>&1 \
    || gws gmail +send --to "$EMAIL_TO" \
         --subject "State of the Estate — $(date '+%b %d')" \
         --body "$(cat "$REPORT")"
else
  cat "$REPORT"
fi
