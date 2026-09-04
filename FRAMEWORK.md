# System Housekeeping Framework

A repeatable way to find and fix system cruft before it costs you time, space, energy, or risk.
Built 2026-06-06. Re-run `./audit.sh` anytime to regenerate findings.

## The 6 principles

1. **Measure before you cut.** Profile and get numbers first. Guessing wastes effort and risks
   breaking something that wasn't actually the problem. (The shell-startup fix came from `zprof` +
   `/usr/bin/time`, not a hunch.)
2. **Four lenses.** Every opportunity falls into one of: **Time, Space, Energy, Entropy.** Sweep all
   four so nothing hides.
3. **Triage by Impact ÷ Effort.** Do the cheap, high-payoff wins first. Score each finding and sort.
4. **Automate over discipline.** Don't rely on remembering to clean. Convert one-time cleanups into
   self-healing systems: cache invalidation, lazy-loading, scheduled jobs. (The openclaw cache now
   auto-refreshes on upgrade — zero future thought required.)
5. **Reversible & logged.** Prefer changes that regenerate or can be undone. Anything destructive
   gets confirmed and logged before it runs.
6. **A silent monitor is not a monitor.** Measuring something and writing it to a log nobody
   reads is indistinguishable from not measuring it. Every probe that can detect a problem needs
   a path to a human — and that path must stay quiet when things are fine, or it gets ignored
   too. (Learned 2026-09-04: three weekly runs logged free space falling 40 → 21 → 15 GB and
   escalated to no one. The disk hit 100%.)

## The 4 lenses

| Lens | The question | Probes |
|------|--------------|--------|
| **Time** | What adds latency I *feel*? | shell startup (`zprof`), external `eval`/`source` cost, `$PATH` length & dupes, compinit caching, slow prompts, per-command hook overhead |
| **Space** | What's eating disk I can reclaim? | `df -h`, `du` on home/Caches, build-artifact sprawl (node_modules, DerivedData), package-manager caches (uv/npm/pip/brew/docker), Downloads/Desktop, old toolchain versions |
| **Energy** | What runs constantly and burns CPU/RAM/battery? | `ps` top CPU/mem, LaunchAgents/Daemons, login items, update daemons, duplicate background services, failed launchd jobs |
| **Entropy** | What's drifting stale or risky? | outdated packages (brew/npm/pip), deprecated/unmaintained apps, broken symlinks, .DS_Store sprawl, stale dotfiles/keys, abandoned project dirs |

## The triage model

For each finding capture: **Impact** (High/Med/Low — seconds, GB, watts, or risk) and **Effort**
(High/Med/Low — minutes + reversibility). Then sort into three buckets:

- **Now** — High impact, Low effort. Reversible. Just do these.
- **Schedule** — recurring or medium-effort. Turn into an automated job (principle 4).
- **Decide** — needs a human judgment call (is this app still used? keep this key?). Don't automate.

## Cadence

- **Weekly (automated):** cache purges + docker prune + brew cleanup + dormant build
  artifacts (60+ days idle) → `reclaim-safe.sh` via launchd. Emails only on low disk or failure.
- **On alert (minutes):** when the weekly job emails, run `./reclaim-deep.sh --dry-run`,
  then execute. This is the manual tier: VM images, simulators, stale worktrees.
- **Monthly (5 min):** run `./audit.sh`, action the "Now" bucket, review "Decide" items.
- **Quarterly:** package upgrades (`brew upgrade`, `npm -g update`), prune old toolchain versions,
  cull abandoned projects and dead keys.

## Files

- `audit.sh` — read-only. Sweeps all four lenses, prints a prioritized report. Changes nothing.
- `reclaim-safe.sh` — purges only regenerable caches; reports GB freed. Safe to run anytime/weekly.
- `doctor.sh` — read-only. Asserts the startup wins haven't regressed; exits nonzero if any did.
- `orphans.sh` — read-only. Flags launchd jobs and system extensions whose owning app is gone.
- `install.sh` + `com.user.housekeeping.plist.template` — (optional) install a per-user launchd job to run `reclaim-safe.sh` weekly.
- `warden.sh` + `com.corey.warden.plist.template` — the Projects Estate warden: scans ~/Projects,
  writes `.warden/manifest.tsv` + `report.md`, regenerates `~/Projects/INDEX.md`, and on Mondays
  (7:45am launchd) emails the "State of the Estate" via gws and drafts filing proposals. System
  definition: `~/Projects/PROJECTS.md`. Paired with the `monday-estate-review` scheduled Claude session (8:07am).
