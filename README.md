# Mac Health

Menu-bar Mac app that watches for the "system feels slow / terminals won't
open" state — long uptime, swap pressure, low disk space, zombie shell
processes, stale agent sessions, runaway MDM (Jamf) CPU — and lets you clean
it up or reboot from a menu.

Single-file SwiftUI app. No Xcode project, no third-party dependencies, no
forked subprocesses in the steady-state loop (uptime/load/swap/memory/process
listing all come from direct syscalls, not `ps`/`uptime`/`sysctl` shell-outs).

Requires macOS 13+ and the Xcode Command Line Tools (`xcode-select --install`)
for `swiftc`.

## Install

```
git clone https://github.com/shlior7/mac-health.git
cd mac-health
./install.sh
```

This builds the app to `~/Applications/MacHealth.app`, registers a
per-user LaunchAgent so it starts automatically at login, and launches it.
Nothing is installed system-wide and no `sudo` is required.

## Uninstall

```
./uninstall.sh
```

## Rebuilding after an edit

```
./build.sh
```

## What it does

- Checks uptime, swap, available memory, disk free space, top CPU process,
  idle shell count, and stale Claude/agent-session count. Checks every 10
  min while healthy, every 60s while something's flagged.
- Sends a macOS notification (throttled to once/day per issue) when a
  threshold is crossed: uptime ≥ 7 days, swap ≥ 70%, available memory < 15%,
  disk free < 10GB, > 20 idle shells, Jamf CPU ≥ 20%.
- Sends a weekly summary notification regardless of severity.
- Menu-bar icon shows a short badge (e.g. `SWAP`, `7d`) when something needs
  attention, so you don't have to open the menu to notice.
- Menu buttons to terminate idle shells, terminate stale agent sessions, or
  reboot — each requires confirmation. Cleanup never touches this app's own
  process lineage (the shell it happens to be running under, if any).
