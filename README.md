# Mac Health

Menu-bar Mac app that watches for the "system feels slow / terminals won't
open" state (long uptime, swap pressure, zombie shell processes, stale agent
sessions, runaway Jamf CPU) and lets you clean it up or reboot from a menu.

Single-file SwiftUI app, no Xcode project, no dependencies.

## Build

```
./build.sh
```

Builds `~/Applications/MacHealth.app`.

## Run at login

```
launchctl load ~/Library/LaunchAgents/com.liorsht.machealthmonitor.plist
```

(copy `com.liorsht.machealthmonitor.plist` there first, pointing at your home dir)

## What it does

- Checks every 5 min: uptime, swap %, free memory %, Jamf CPU, idle shell
  count, stale Claude/agent session count.
- Sends a macOS notification (throttled to once/day per issue) when a
  threshold is crossed: uptime ≥ 7 days, swap ≥ 70%, free memory < 15%,
  > 20 idle shells, Jamf CPU ≥ 20%.
- Sends a weekly summary notification regardless of severity.
- Menu buttons to terminate idle shells, terminate stale agent sessions, or
  reboot — each requires confirmation.
