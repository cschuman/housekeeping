# housekeeping

A small, repeatable framework for finding and fixing system cruft on macOS before it costs you
time, disk space, battery, or security. Read-only audit first, safe automated cleanup second.

It started as a one-off "why does my terminal take 10 seconds to open" investigation and turned
into a reusable method. See [FRAMEWORK.md](FRAMEWORK.md) for the thinking behind it.

## What's here

| File | What it does |
|------|--------------|
| `audit.sh` | Read-only. Sweeps four lenses (Time, Space, Energy, Entropy) and prints a prioritized report. Changes nothing. |
| `reclaim-safe.sh` | Purges regenerable caches (uv, npm, npx, pip, yarn, pnpm, Homebrew, Docker), then build artifacts in projects dormant 60+ days. Emails via `gws` **only** when disk is low or a step failed. Safe to run anytime. Supports `--dry-run`. |
| `reclaim-deep.sh` | Manual-only heavy reclaim: Claude sandbox VM image, iOS simulators, self-updater caches, stale `.claude` worktrees. Refuses to delete a VM that is running; worktrees are report-only unless `--remove-worktrees`. Supports `--dry-run`. |
| `doctor.sh` | Read-only. Checks that the shell-startup wins haven't regressed: fast startup, no duplicate `$PATH`, no per-launch completion generation, nvm lazy-loaded, oh-my-zsh auto-update off. Exits nonzero on any regression. |
| `orphans.sh` | Read-only. Finds launchd jobs and system extensions whose owning app is gone (half-uninstalled leftovers still running in the background). |
| `install.sh` | Installs a per-user launchd job that runs `reclaim-safe.sh` weekly, so caches never pile up again. |
| `FRAMEWORK.md` | The method: 5 principles, 4 lenses, an Impact/Effort triage model, and a maintenance cadence. |

## Quick start

```bash
git clone https://github.com/cschuman/housekeeping.git
cd housekeeping

./audit.sh                 # see what's reclaimable (read-only, safe)
./reclaim-safe.sh --dry-run   # preview the cache purge
./reclaim-safe.sh          # actually reclaim regenerable caches
./reclaim-deep.sh --dry-run   # preview the heavy reclaim (VM image, sims, worktrees)
./doctor.sh                # check the startup wins haven't regressed (read-only)
./orphans.sh               # find leftover daemons/extensions with no owning app (read-only)
./install.sh               # optional: schedule the weekly auto-cleanup
```

## The idea in one paragraph

Most "my Mac feels slow / full" problems come from four places: latency you feel (shell startup,
slow tool inits), disk you can reclaim (package-manager caches, build artifacts), background load
(login items, daemons), and slow-accumulating cruft (outdated packages, stale dotfiles). Sweep all
four, score each finding by impact over effort, do the cheap wins first, and turn the recurring ones
into self-healing automation instead of relying on yourself to remember. The first run on the
author's machine reclaimed about 19 GB and took shell startup from 2.5s to 0.14s.

## Why there are two reclaim scripts

On 2026-09-04 this machine hit 100% full — 3.4 GB free of 460 GB — while the weekly
job was running fine. Its log told the whole story:

```
Freed ~0.7 GB. Now available: 40Gi
Freed ~0.4 GB. Now available: 21Gi
Freed ~0.9 GB. Now available: 15Gi
```

Three weekly runs watched the disk drain by 25 GB and freed under 1 GB each, because
none of the categories it cleaned were where the space went: 28 GB of build artifacts,
a 10 GB VM image, 32 GB of image-editing scratch, 5 GB of simulators. `audit.sh`
*probed* for build sprawl but `reclaim-safe.sh` could not act on it, and nothing
escalated to a human. Four fixes came out of it:

1. **Escalation.** Low disk now emails (15% warn / 8% critical), naming the biggest
   offenders. There is deliberately **no** healthy-state digest — a weekly email that
   always arrives is one you stop reading, which is how 40 → 21 → 15 GB slid by.
2. **Failures surface.** The old `run()` sent stderr to `/dev/null`, hiding a
   `pnpm store prune` failure that recurred silently every week under launchd's PATH.
3. **Docker actually prunes.** `docker system prune -f` leaves unused tagged images
   and every named volume in place — 3.1 GB was still sitting there after each run.
4. **The heavy stuff got its own script.** `reclaim-deep.sh`, manual by design,
   because deleting VM images and git worktrees wants a human in the loop (principle 5).

## Notes

- Everything both reclaim scripts delete regenerates on demand (caches re-download,
  builds rebuild, VM images re-provision). The difference is how long regenerating
  takes: seconds for `reclaim-safe.sh`, minutes for `reclaim-deep.sh`.
- `reclaim-safe.sh` never touches a project with activity in the last 60 days, so
  automatic artifact cleanup will not cost you a rebuild on work in progress.
- `reclaim-deep.sh` refuses to delete the sandbox VM image while a VM holds it open.
- `audit.sh` never modifies anything, so it is safe to run on any machine to just look.
- Designed for Apple Silicon macOS with Homebrew, but the probes degrade gracefully if a tool is absent.

## License

MIT. See [LICENSE](LICENSE).
