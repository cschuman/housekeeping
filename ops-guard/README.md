# ops-guard

Claude Code hooks that stop sessions colliding on daemons and gate money, prod DB and outbound email,
plus `healthcheck.sh`. Staged here; `./install.sh` installs (review `settings.diff` first).

## Rules (`hooks/ops-guard.py`, PreToolUse on `Bash` and `mcp__Neon__.*`)
Leading `rtk ` / `rtk proxy ` is stripped first. First match wins; a lock deny beats everything.

| Rule | Effect |
|---|---|
| Daemon lock | Commands that restart/kill/deploy a daemon (kalshi hot loop, crypto-desk, netmap, casablanca, site keepalives, steno, launchctl/systemctl/kill) take `~/.claude/locks/<key>.lock`. Another live session holding it gets **deny**; locks older than 600 s are replaced; same session re-enters. Read-only mentions (`ssh casa 'tail .../hot_loop.log'`) never lock. |
| Money | `touch/cp/mv/> state/ARMED`, `rm state/HALT`, `bin/arm`, `-m src.execute/decide/run_*`, `scripts/hot_cycle.sh` -> **ask**. |
| Prod DB / secrets | `pnpm migrate`, `migrate:latest`, `tsx ...migrate`, `DATABASE_URL_DIRECT=`, `MIGRATE_ALLOW_REMOTE`, `fly postgres connect`, `fly ssh console -C psql/...`, `fly secrets set/unset/import/deploy`, and `psql` on `neon.tech`/`$DATABASE_URL` unless every `-c` statement is `select/explain/show/\d` -> **ask**. |
| Email | `gws gmail users messages/drafts send`: recipients read from the base64 `raw` (inline `--json`, `"$(cat FILE)"`, `@FILE`). All in the known list -> **allow**; any unknown -> **ask** naming only those; unreadable -> **ask**. `+send` checks `--to/--cc/--bcc` (attachments -> ask); `+reply`/`+forward` -> ask. |
| Read-only ssh | `ssh casa|baby-bear-box|game-time '<cmd>'` where every segment is a read verb (tail, cat, grep, crontab -l, systemctl status, git log, curl GET, ...) and there are no redirects or substitutions -> **allow**. |
| Neon | `run_sql(_transaction)` with only SELECT/WITH/EXPLAIN/SHOW/VALUES and no write keyword -> **allow**, else **ask**; delete_/reset_/create_/update_/... tools -> **ask**. |
| Anything else | no opinion (normal permission flow). |

**Ask never takes a lock.** If you approve an `ask`, the command runs unlocked, because PostToolUse does
not fire for a declined call and the lock would otherwise be orphaned. Locks are taken only on allow /
no-opinion and released by `hooks/ops-lock-release.py` (registered on PostToolUse and PostToolUseFailure)
when that call finishes. A call that ends with neither event (killed session) leaves the lock to expire
after 600 s; a lock with a future timestamp counts as stale.

## Add a known recipient
`echo 'name@example.com' >> ~/.claude/known-recipients.txt` (one lowercase address per line, `#` comments ok).
Reseed from sent mail: `./seed-known-recipients.sh`, then copy the result over by hand (install.sh never
clobbers an edited list).

## Clear a lock
See holders: `cat ~/.claude/locks/*.lock`. Clear one: `rm ~/.claude/locks/<key>.lock` (the deny message prints
the exact path). `healthcheck.sh` warns about any lock older than 600 s.

## Files
`hooks/ops-guard.py`, `hooks/ops-lock-release.py`, `hooks/ops-guard.test.py` (`python3 hooks/ops-guard.test.py`),
`healthcheck.sh` (`--local-only`, `--quiet`), `seed-known-recipients.sh`, `build-settings.py` (regenerates
`settings.proposed.json` + `settings.base.sha256`), `settings.diff`, `install.sh`.
