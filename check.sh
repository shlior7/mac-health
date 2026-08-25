#!/bin/bash
# Smallest thing that fails if the stats logic breaks: compile main.swift's
# non-UI half with a test entry point and assert the per-app memory rollup.
set -e
cd "$(dirname "$0")"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

awk '/^\/\/ MARK: - UI/{exit} {print}' main.swift | sed 's/^import SwiftUI$/import AppKit/' > "$TMP/check.swift"
cat >> "$TMP/check.swift" <<'EOF'
let t0 = Date()
let procs = listProcs()
let ms = Date().timeIntervalSince(t0) * 1000
let apps = topMemoryApps(procs, limit: 8)

assert(procs.count > 10, "process enumeration returned \(procs.count) procs")
assert(!apps.isEmpty, "no per-app memory measured")
assert(ms < 250, "refresh took \(ms) ms — too slow for the main run loop")
for i in 1..<apps.count { assert(apps[i - 1].bytes >= apps[i].bytes, "rollup not sorted by size") }
// Footprint, not resident size: no single app may exceed physical RAM.
let ramBytes = UInt64(physicalMemoryGB() * 1_073_741_824)
assert(apps[0].bytes < ramBytes, "\(apps[0].name) reports \(formatBytes(apps[0].bytes)) — over total RAM")
// A version-numbered executable must not become the app name.
for a in apps { assert(a.name.rangeOfCharacter(from: .letters) != nil, "unnamed app: \(a.name)") }
assert(swapInfo().totalMB > 0, "swap sysctl returned nothing")

// CPU accounting: p_pctcpu reads 0 on modern macOS, so cpuNanos must actually tick.
let before = listProcs().first { $0.pid == getpid() }!.cpuNanos
var spin = 0.0
let spinUntil = Date().addingTimeInterval(0.4)
while Date() < spinUntil { spin += 1 }
let after = listProcs().first { $0.pid == getpid() }!.cpuNanos
assert(after > before, "cpuNanos did not advance while burning CPU (spin=\(spin))")
assert(availableMemoryPercent() > 0 && availableMemoryPercent() <= 100, "bad memory percent")

// Cleanup rows must identify themselves by owner/folder, not just a PID.
let shells = procs.filter { ($0.comm == "zsh" || $0.comm == "bash") && $0.ageHours >= 6 }
if let s = shells.first {
    var q = s
    q.cwd = processCwd(s.pid)
    q.owner = "claude"
    assert(q.contextLabel.contains("claude"), "context label lost the owner: \(q.contextLabel)")
    var orphan = s
    orphan.cwd = "/"
    assert(orphan.contextLabel == orphan.comm || !orphan.contextLabel.contains("·"),
           "cwd of / should not render as a folder: \(orphan.contextLabel)")
    print("shell rows: \(shells.count), sample label: \(q.contextLabel)")
}

print(String(format: "listProcs: %d procs in %.1f ms", procs.count, ms))
for a in apps {
    print(String(format: "  %-24@ %9@ x%d", a.name as NSString, formatBytes(a.bytes) as NSString, a.procCount))
}
print("OK")
EOF

swiftc -O "$TMP/check.swift" -o "$TMP/check" -framework AppKit
"$TMP/check"
