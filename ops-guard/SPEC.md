# ops-guard: build spec (authority for this build)

Goal: STAGE (do not install) a Claude Code permission allowlist + PreToolUse/PostToolUse hooks and a
healthcheck.sh preflight. Everything lands under `~/Projects/housekeeping/ops-guard/`. Nothing is
copied into `~/.claude/` and `~/.claude/settings.json` is NOT modified. Corey reviews the diff first.

Decisions already made by Corey (2026-10-09), do not re-ask:
- Target settings file: `~/.claude/settings.json` (global). Produce `settings.proposed.json` = the
  current file with additions merged, plus `settings.diff` (`diff -u` of current vs proposed).
- Lock release: PostToolUse hook releases; stale locks reclaimed after 600 s.
- Known recipients: allowlist file seeded from the last 90 days of sent mail (read-only gws).
- healthcheck.sh lives at `~/Projects/housekeeping/healthcheck.sh` (write it to
  `ops-guard/healthcheck.sh`; install.sh symlinks/copies it up one level).

Existing conventions to match: `~/.claude/hooks/agent-preflight.py` (+ `.test.py`) is the house style:
python3 stdlib only, fail-open on unreadable payload, JSON decision on stdout, exit 0. Read it first.
Also read `~/.claude/hooks/rtk-rewrite.sh`: it runs in parallel on the same Bash PreToolUse event and
may return `updatedInput` with an `rtk ...` prefix. Our hook must therefore match commands that start
with optional `rtk proxy ` / `rtk ` prefixes, and must never itself return updatedInput.

Hook I/O contract (Claude Code): stdin JSON with `session_id`, `tool_use_id` (may be absent),
`tool_name`, `tool_input`, `cwd`. Decision = stdout JSON
`{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow|ask|deny","permissionDecisionReason":"..."}}`.
No stdout + exit 0 = no opinion (normal permission flow). Reasons must be one short sentence and
must never echo secrets or full email bodies.

## Files to produce

1. `hooks/ops-guard.py` (PreToolUse; matcher `Bash` and matcher `mcp__Neon__.*`)
2. `hooks/ops-lock-release.py` (PostToolUse; matcher `Bash`)
3. `hooks/ops-guard.test.py` (unittest, runs with `python3 hooks/ops-guard.test.py`)
4. `seed-known-recipients.sh` + its output `known-recipients.txt` (run it; read-only gws calls)
5. `healthcheck.sh` (run it; save output to `healthcheck.out`)
6. `settings.proposed.json`, `settings.diff`
7. `install.sh` (NOT run): backs up `~/.claude/settings.json` to `~/.claude/settings.json.bak-<date>`,
   copies hooks to `~/.claude/hooks/`, `known-recipients.txt` to `~/.claude/known-recipients.txt`,
   `mkdir -p ~/.claude/locks`, copies healthcheck.sh to `~/Projects/housekeeping/healthcheck.sh`,
   writes settings.proposed.json over settings.json. Idempotent. Prints what it did.
8. `README.md`: one screen: what each rule does, how to add a recipient, how to clear a lock.

## 1. ops-guard.py rules (Bash tool)

Normalise: `cmd = tool_input.command`; strip leading `rtk proxy ` or `rtk `; evaluate rules in this
order, first match wins. Regexes are case-sensitive unless noted.

### 1a. Process lock (evaluated FIRST, before ask/allow; lock dir `$OPS_LOCK_DIR` or `~/.claude/locks`)
A command "touches a daemon" when it matches any of:
- kalshi hot loop: `hot_loop|hot_cycle|kalshi-desk/(scripts|cron)/(activate_release|deploy|install_cron)` or `kalshi-desk.*(pkill|kill|restart)`  -> key `casa-kalshi-hot-loop`
- crypto-desk: `crypto-desk.*(bin/halt|bin/arm|install_cron|pkill|kill)` -> `casa-crypto-desk`
- netmap: `netmap-run|netmap serve|(pkill|kill).*netmap` -> `casa-netmap`
- casablanca: `casablanca-run|(pkill|kill).*casablanca` -> `casa-casablanca`
- site keepalives: `(site_run|site-run|desk_site_keepalive)\.sh|(pkill|kill).*(nuggest|family-wealth|llm-spend|claude-burn)` -> `casa-<repo>` (derive repo from the path/word; fallback `casa-site`)
- steno: `com\.steno\.daemon|steno-daemon|(pkill|killall).*steno|"cmd"\s*:\s*"(start|stop)"` -> `local-steno`
- any other `launchctl (kickstart|bootout|bootstrap|unload|load|stop|start)` -> `local-launchd-<label>` (label = last `com\.[a-z0-9.-]+` token, else `unknown`)
- any other `systemctl( --user)? (restart|stop|start|kill)` or bare `pkill|killall|kill -?(9|15|TERM|KILL|HUP)` -> `proc-<first non-flag word after the verb>`
Read-only mentions do NOT lock: if the command's only verbs are read verbs (see 1c list) it is not a
daemon touch even if it names a daemon (e.g. `ssh casa 'tail -50 ~/kalshi-desk/logs/hot_loop.log'`).

Lock file `<dir>/<key>.lock`, JSON `{"session_id","tool_use_id","cmd":<first 120 chars>,"ts":epoch}`.
Acquire with `os.open(O_CREAT|O_EXCL)`. If it exists: if `ts` older than 600 s -> replace (stale);
if `session_id` == ours -> allow (re-entrant); else -> `deny` with reason
`"<key> is held by session <id[:8]> for <N>s (cmd: ...). Wait or rm ~/.claude/locks/<key>.lock"`.
A denied command takes no lock. A lock is taken even when the same command later evaluates to `ask`
(if the user says no, PostToolUse still fires? It does not; so: when returning `ask`, do NOT take the
lock; take it only when returning `allow` or no-opinion). Document this in README.

### 1b. Ask rules (return `ask`)
- money-moving (kalshi-desk / crypto-desk): `touch .*state/ARMED`, `rm .*state/HALT`, `bin/arm`,
  `-m src\.(execute|decide|run_trend|run_requote|run_wick|run_flush)`, `scripts/hot_cycle\.sh`.
  (`-m src\.(settle|report|canary|hq|status)` and `scripts/status\.py` are NOT money-moving.)
- prod DB writes: `pnpm (run )?migrate`, `migrate:latest`, `tsx .*migrate`, `DATABASE_URL_DIRECT=`,
  `MIGRATE_ALLOW_REMOTE`, `fly postgres connect`, `fly ssh console .*-C .*(psql|migrate|pnpm|node|tsx)`,
  `fly secrets (set|unset|import|deploy)`, and `psql` whose argv contains `neon\.tech` or `\$DATABASE_URL`
  unless every `-c` payload starts with `select|explain|show|\\d` (case-insensitive).
- outbound email: `gws gmail users (messages send|drafts send)` (any argument order).
  Recipient extraction: find `--json` payload: a single-quoted or double-quoted literal, or
  `"$(cat FILE)"` / `$(cat FILE)` / `@FILE`; resolve FILE against `cwd`; parse JSON; take `raw`
  (or `message.raw`); base64url-decode (add padding); parse with `email.parser` header-only;
  collect To/Cc/Bcc addresses via `email.utils.getaddresses`, lowercase. Known list = lines of
  `$OPS_KNOWN_RECIPIENTS` or `~/.claude/known-recipients.txt` (lowercase, `#` comments, blank ok).
  All known -> `allow` with reason `"email to <n> known recipient(s)"`. Any unknown -> `ask` with
  reason naming ONLY the unknown addresses. Undecodable -> `ask` `"could not determine recipients"`.
  Never print subject or body.

### 1c. Read-only ssh auto-allow (return `allow`)
Command starts with `ssh ` to a host matching `(casa|corey@casa[^ ]*|casa\.tailb77fc\.ts\.net|baby-bear-box|game-time)`.
Split the remote command (strip one layer of surrounding quotes) on `&&`, `;`, `||`, `|`; each
segment's first word (after `env`/`PATH=...`/`cd X &&` style prefixes) must be in READ_VERBS =
`tail head cat ls stat wc grep rg find df du uptime free date pgrep ps crontab journalctl ss curl echo printf test [ true id hostname which`,
with these qualified forms: `crontab` only with `-l`; `systemctl` only with
`status|list-timers|list-units|is-active|show`; `git` only with `status|log|rev-parse|diff|show|branch|remote`;
`tailscale` only with `status|ping|ip`; `curl` only without `-X`/`-d`/`--data`/`-F`/`-T`; `python3 -m src.(status|hq)` allowed.
Any segment failing -> no opinion (fall through). Redirections `>`/`>>` anywhere -> no opinion.

### 1d. Otherwise: no output, exit 0.

## 2. ops-guard.py rules (Neon MCP tools, tool_name starts with `mcp__Neon__`)
- `run_sql` / `run_sql_transaction`: statements from `tool_input.sql` or `tool_input.sqlStatements`;
  strip `--` and `/* */` comments; every statement must start (ci) with `select|with|explain|show|values`
  and a `with` statement must not contain `insert|update|delete|merge` -> `allow`; else `ask` naming the first verb.
- names matching `^mcp__Neon__(delete_|reset_|rotate_|restore_|revoke_|suspend_|start_|set_default|complete_database_migration|prepare_database_migration|create_|update_|provision_|deploy_|register_|finalize_|recover_|disable_)` -> `ask`.
- everything else -> no opinion.

## 3. ops-lock-release.py (PostToolUse Bash)
Read `session_id`, `tool_use_id`. Remove every `*.lock` in the lock dir whose `session_id` matches
and (`tool_use_id` matches or the lock has no tool_use_id or payload has none). Fail open, never print.

## 4. settings.proposed.json additions (merge, keep everything already there, keep key order)
permissions.allow add (minimal, read-only/repeatable):
```
Bash(fly status:*) Bash(fly releases:*) Bash(fly apps list:*) Bash(fly secrets list:*) Bash(fly machine list:*) Bash(fly checks list:*) Bash(fly auth whoami:*)
Bash(gws auth status:*) Bash(gws gmail users getProfile:*) Bash(gws gmail users messages list:*) Bash(gws gmail users messages get:*) Bash(gws gmail users threads get:*) Bash(gws gmail users threads list:*) Bash(gws sheets spreadsheets get:*) Bash(gws sheets spreadsheets values get:*) Bash(gws calendar events list:*)
Bash(tailscale status:*) Bash(tailscale ping:*) Bash(tailscale ip:*)
Bash(crontab -l) Bash(launchctl list:*) Bash(launchctl print:*) Bash(pgrep:*)
Bash(/Users/corey/Projects/housekeeping/healthcheck.sh:*) Bash(~/Projects/housekeeping/healthcheck.sh:*)
```
permissions.ask add: `Bash(fly secrets set:*)`, `Bash(fly secrets unset:*)`, `Bash(fly secrets import:*)`, `Bash(fly postgres connect:*)`, `Bash(psql:*)`.
Do NOT touch `permissions.deny` or `defaultMode`. Do not touch `~/.claude/settings.local.json`.
hooks.PreToolUse: append `{matcher:"Bash", hooks:[{type:"command", command:"/Users/corey/.claude/hooks/ops-guard.py", timeout:10}]}` and
`{matcher:"mcp__Neon__.*", hooks:[... same ...]}`. hooks.PostToolUse (new key if absent): `{matcher:"Bash", hooks:[{type:"command", command:"/Users/corey/.claude/hooks/ops-lock-release.py", timeout:5}]}`.
Produce `settings.diff` with `diff -u ~/.claude/settings.json settings.proposed.json`.

## 5. seed-known-recipients.sh
`gws gmail users messages list --params '{"userId":"me","q":"in:sent newer_than:90d","maxResults":100}'`,
follow `nextPageToken` up to 5 pages; for each id `gws gmail users messages get` with
`format=metadata, metadataHeaders To,Cc,Bcc`; extract addresses (python `email.utils.getaddresses`),
lowercase, unique, sorted -> `known-recipients.txt` with a header comment line (`# seeded <date> from 90d sent mail; one address per line`).
Must contain `kavs68@gmail.com` and `cschuman@gmail.com` (append if missing). Report only the COUNT in your summary, never the addresses.

## 6. healthcheck.sh
bash, `set -u`, every network call wrapped in `timeout`/`ssh -o ConnectTimeout=8 -o BatchMode=yes`.
Flags: `--local-only` (skip casa), `--quiet` (only FAIL/WARN lines). Output one line per check:
`PASS|FAIL|WARN  <id>  <detail>  fix: <one-line command or action>` aligned columns, summary line
`N pass, N warn, N fail`, exit 1 if any FAIL. Checks:
1. gws-token: `gws auth status` -> `token_valid` true. fix `gws auth login`
2. gws-scopes: scopes include gmail.send, gmail.readonly, spreadsheets, calendar. fix `gws auth login` (re-consent)
3. gws-gmail-live: `gws gmail users getProfile` returns emailAddress. fix `gws auth login`
4. fly-auth: `fly auth whoami`. fix `fly auth login`
5. fly-secrets-oddmind-hq: names present: DATABASE_URL DATABASE_URL_DIRECT BETTER_AUTH_SECRET INGEST_TOKEN ANTHROPIC_API_KEY. fix `fly secrets set <NAME>=... -a oddmind-hq`
6. fly-secrets-oddmind-apps: DATABASE_URL DATABASE_URL_DIRECT BETTER_AUTH_SECRET RESEND_API_KEY. same fix shape
7. fly-machines: `fly status -a <app>` shows a started machine for oddmind-hq and oddmind-apps. fix `fly machine start -a <app>`
8. tailscale-local: BackendState Running and Self.Online; WARN if KeyExpiry < 14 days. fix `tailscale up`
9. casa-ssh: `ssh casa true`. fix "power/tailscale on casa; ssh casa"
10. casa-tailscale: remote BackendState Running. fix `ssh casa sudo tailscale up` (note sudo-free box; say "run tailscale up on casa")
11. casa-cron: remote `crontab -l` contains each marker: `kalshi-desk BEGIN`, `crypto-desk BEGIN`, `netmap-run.sh`, `casa-watchdog run`, `llm-spend/casa/run-daily.sh`, `nuggest.*daily.sh`, `casablanca-run.sh`. fix: that repo's `cron/install_cron.sh` (or re-add the line)
12. casa-kalshi-hot-loop: remote pid file `~/kalshi-desk/state/hot_loop.pid` alive AND `logs/hot_loop.log` mtime < 5 min. fix `ssh casa '~/kalshi-desk/scripts/hot_loop_keepalive.sh'`. WARN (not FAIL) if `state/HALT` exists, say so.
13. casa-sites: HTTP 200 from `http://casa.tailb77fc.ts.net:<port>/` for 8765 nuggest, 8766 kalshi, 8767 family-wealth, 8768 claude-burn, 8769 netmap, 8770 llm-spend (one line each; fix = the repo's site-run script per the crontab you read above).
14. casa-netmap-proc: remote `pgrep -f "netmap serve"`. fix `ssh casa ~/.local/bin/netmap-run.sh`
15. steno-daemon: `launchctl print gui/$(id -u)/com.steno.daemon` exists; then query the daemon's status over its unix socket (find the socket path and the JSON status command in `~/Projects/steno` daemon source; do not guess) with python3; PASS if recording/listening, WARN if `paused` (Corey's choice, never auto-resume), FAIL if `error`/`idle`/no socket. fix: `printf '{"cmd":"start"}' | nc -U <socket>` (verify nc -U works on macOS, else python one-liner).
16. launchd-local: each of `com.steno.daemon com.corey.housekeeping com.corey.warden com.corey.claude-burn health.oddmind.claude-memory-backup com.corey.gmail-morning-cleanup com.corey.usage-sentinel` appears in `launchctl list`. fix `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/<label>.plist`
17. claude-locks: any `~/.claude/locks/*.lock` older than 600 s -> WARN. fix `rm <path>`
18. geoff-dryrun-marker: WARN if `~/.claude/scheduled-tasks/geoff-daily-mail/DRYRUN` exists. fix `rm` it
Run it once for real and save to `healthcheck.out`. Do not fix anything it finds.

## 7. Tests (hooks/ops-guard.test.py)
Use a temp lock dir and a temp known-recipients file via env vars. Cases, each asserting the
decision string (or no output):
lock: acquire -> allow/no-opinion and file exists; second session same key -> deny mentioning the key;
stale (ts-700) -> replaced; same session -> allowed; release removes it; `ask` path takes no lock;
read-only mention of a daemon takes no lock.
ask: `touch ~/kalshi-desk/state/ARMED`, `ssh casa 'rm ~/kalshi-desk/state/HALT'`, `~/crypto-desk/bin/arm`,
`python3 -m src.execute`, `pnpm run migrate`, `DATABASE_URL_DIRECT=x pnpm migrate:latest`,
`fly secrets set X=1 -a oddmind-hq`, `fly ssh console -a oddmind-hq -C "psql $DATABASE_URL"`,
`psql postgres://u@ep.neon.tech/db -c "update t set x=1"`; `rtk proxy python3 -m src.decide`.
allow: `psql ... -c "select 1"`, `python3 -m src.settle`, `ssh casa 'tail -50 ~/kalshi-desk/logs/hot_loop.log'`,
`ssh casa "crontab -l; systemctl --user list-timers"`, send to known recipient (build a real base64url MIME
fixture inline AND via `$(cat file)` in a temp cwd), send to known+unknown -> ask naming only the unknown,
send with unparsable payload -> ask.
neon: select -> allow; `with x as (...) select` -> allow; insert -> ask; `mcp__Neon__delete_branch` -> ask; `mcp__Neon__list_projects` -> no opinion.
no-opinion: `git status`, `ls -la`, `ssh casa 'echo hi > /tmp/x'`.
Run the tests; all must pass. Also run `python3 -m py_compile` on both hooks and `bash -n` on the shell scripts.

## Return contract
Return a compact summary: file list with line counts, test result line, the `healthcheck.out`
content verbatim, the `settings.diff` verbatim, the recipient COUNT, and any spec point you could not
meet or had to interpret (say which and how). No raw file dumps beyond those two. Do not install anything.
Do not modify anything outside `~/Projects/housekeeping/ops-guard/`.
