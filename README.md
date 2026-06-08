# housekeeping

A small, repeatable framework for finding and fixing system cruft on macOS before it costs you
time, disk space, battery, or security. Read-only audit first, safe automated cleanup second.

It started as a one-off "why does my terminal take 10 seconds to open" investigation and turned
into a reusable method. See [FRAMEWORK.md](FRAMEWORK.md) for the thinking behind it.

## What's here

| File | What it does |
|------|--------------|
| `audit.sh` | Read-only. Sweeps four lenses (Time, Space, Energy, Entropy) and prints a prioritized report. Changes nothing. |
| `reclaim-safe.sh` | Purges only regenerable caches (uv, npm, pip, yarn, pnpm, Homebrew, Docker) and reports GB freed. Safe to run anytime. Supports `--dry-run`. |
| `install.sh` | Installs a per-user launchd job that runs `reclaim-safe.sh` weekly, so caches never pile up again. |
| `FRAMEWORK.md` | The method: 5 principles, 4 lenses, an Impact/Effort triage model, and a maintenance cadence. |

## Quick start

```bash
git clone https://github.com/cschuman/housekeeping.git
cd housekeeping

./audit.sh                 # see what's reclaimable (read-only, safe)
./reclaim-safe.sh --dry-run   # preview the cache purge
./reclaim-safe.sh          # actually reclaim regenerable caches
./install.sh               # optional: schedule the weekly auto-cleanup
```

## The idea in one paragraph

Most "my Mac feels slow / full" problems come from four places: latency you feel (shell startup,
slow tool inits), disk you can reclaim (package-manager caches, build artifacts), background load
(login items, daemons), and slow-accumulating cruft (outdated packages, stale dotfiles). Sweep all
four, score each finding by impact over effort, do the cheap wins first, and turn the recurring ones
into self-healing automation instead of relying on yourself to remember. The first run on the
author's machine reclaimed about 19 GB and took shell startup from 2.5s to 0.14s.

## Notes

- Everything `reclaim-safe.sh` deletes regenerates on demand (caches re-download, builds rebuild).
- `audit.sh` never modifies anything, so it is safe to run on any machine to just look.
- Designed for Apple Silicon macOS with Homebrew, but the probes degrade gracefully if a tool is absent.

## License

MIT. See [LICENSE](LICENSE).
