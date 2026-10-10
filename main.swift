import SwiftUI
import AppKit
import Darwin

// MARK: - Shell helper (only used for rare, user-triggered actions)

func shell(_ launchPath: String, _ args: [String]) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: launchPath)
    p.arguments = args
    p.standardOutput = nil
    p.standardError = nil
    try? p.run()
}

func notify(_ title: String, _ body: String) {
    shell("/usr/bin/osascript", ["-e", "display notification \"\(body)\" with title \"\(title)\""])
}

// MARK: - Native system stats (no forked processes — direct syscalls)

func uptimeDays() -> Double {
    var boottime = timeval()
    var size = MemoryLayout<timeval>.size
    guard sysctlbyname("kern.boottime", &boottime, &size, nil, 0) == 0 else { return 0 }
    let bootEpoch = Double(boottime.tv_sec) + Double(boottime.tv_usec) / 1_000_000
    return max(0, (Date().timeIntervalSince1970 - bootEpoch) / 86400)
}

func loadAvgString() -> String {
    var loads = [Double](repeating: 0, count: 3)
    guard getloadavg(&loads, 3) == 3 else { return "-" }
    return loads.map { String(format: "%.2f", $0) }.joined(separator: "  ")
}

struct SwapInfo { let usedMB: Double; let totalMB: Double }

func swapInfo() -> SwapInfo {
    var usage = xsw_usage()
    var size = MemoryLayout<xsw_usage>.size
    guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else {
        return SwapInfo(usedMB: 0, totalMB: 0)
    }
    return SwapInfo(usedMB: Double(usage.xsu_used) / 1_048_576, totalMB: Double(usage.xsu_total) / 1_048_576)
}

/// Available memory = free + inactive + purgeable, as a percentage of physical RAM.
/// (Not identical to Activity Monitor's private algorithm, but a standard, honest approximation.)
func availableMemoryPercent() -> Int {
    var stats = vm_statistics64()
    var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &stats) { ptr -> kern_return_t in
        ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPtr in
            host_statistics64(mach_host_self(), HOST_VM_INFO64, reboundPtr, &count)
        }
    }
    guard result == KERN_SUCCESS else { return 100 }
    let totalPages = Double(stats.free_count + stats.active_count + stats.inactive_count
                             + stats.wire_count + stats.speculative_count + stats.compressor_page_count)
    guard totalPages > 0 else { return 100 }
    let availablePages = Double(stats.free_count + stats.inactive_count + stats.purgeable_count)
    return Int((availablePages / totalPages) * 100)
}

func physicalMemoryGB() -> Double {
    Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
}

// MARK: - Process enumeration via KERN_PROC_ALL (no forked `ps`)

struct ProcRecord: Identifiable {
    let id: Int32
    let pid: Int32
    let ppid: Int32
    let comm: String
    let ageHours: Double
    let cpuNanos: UInt64
    let rssBytes: UInt64
    let path: String
    /// Filled in by HealthMonitor from the delta against the previous sample —
    /// the kernel's own `p_pctcpu` is hardwired to 0 on modern macOS.
    var cpuPercent: Double = 0
    /// Working directory and owning app, resolved only for the cleanup lists —
    /// path resolution is the priciest lookup here, so it isn't done for all ~800 procs.
    var cwd: String = ""
    var owner: String = ""
    /// Names of direct child processes — a shell with a running child is doing something.
    var children: [String] = []
    /// CPU burned by direct children — a shell/launcher itself sits at 0% while its children work.
    var childCPU: Double = 0
    /// Dead but not yet reaped by its parent: no cwd, no memory, and SIGTERM does nothing.
    var isZombie = false
    var isActive: Bool { !isZombie && (!children.isEmpty || cpuPercent + childCPU >= 1) }

    /// "claude · my-worktree" — what the shell is actually sitting in, so a row is
    /// identifiable without going hunting for the PID.
    var contextLabel: String {
        let folder = (cwd as NSString).lastPathComponent
        let place = (cwd.isEmpty || cwd == "/") ? nil : folder
        switch (owner.isEmpty ? nil : owner, place) {
        case let (owner?, place?): return "\(owner) · \(place)"
        case let (owner?, nil): return owner
        case let (nil, place?): return place
        default: return comm
        }
    }

    /// Outermost `.app` bundle in the executable path, so the 20 renderer helpers
    /// under Brave Browser.app all roll up to one entry instead of 20.
    var bundlePath: String? {
        guard let r = path.range(of: ".app/") else { return path.hasSuffix(".app") ? path : nil }
        return path[path.startIndex..<r.lowerBound] + ".app"
    }

    /// What a human calls it: the app bundle name, else the first meaningful path
    /// component. `.../claude/versions/2.1.241` reads as "claude", not "2.1.241" —
    /// the kernel's `p_comm` is just the (often versioned) executable filename.
    var appName: String {
        if let b = bundlePath {
            return (b as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")
        }
        let generic: Set<String> = ["bin", "sbin", "libexec", "versions", "installation", "MacOS", "Contents"]
        let named = comm.rangeOfCharacter(from: .letters) != nil && !generic.contains(comm)
        if named || path.isEmpty { return comm }
        for part in path.split(separator: "/").reversed() {
            let name = String(part)
            if name.rangeOfCharacter(from: .letters) != nil && !generic.contains(name) { return name }
        }
        return comm
    }
}

/// Memory usage rolled up per app (all helper processes summed).
struct AppMemory: Identifiable {
    var id: String { name }
    let name: String
    let bundlePath: String?
    let bytes: UInt64
    let procCount: Int
}

/// App icons never change while we're running; fetching one hits the disk, so keep them.
private var iconCache: [String: NSImage] = [:]

func appIcon(for bundlePath: String?) -> NSImage? {
    guard let bundlePath else { return nil }
    if let cached = iconCache[bundlePath] { return cached }
    let icon = NSWorkspace.shared.icon(forFile: bundlePath)
    iconCache[bundlePath] = icon
    return icon
}

/// Physical footprint of a process — the same figure Activity Monitor's "Memory"
/// column shows. Resident size was tried first and rejected: it counts shared
/// library pages once per process, which inflated a 62-helper browser to 9 GB.
///
/// Only readable for processes we own; root-owned system daemons return 0 without
/// elevated privileges and are left out of the rollup rather than reported as free.
///
/// `proc_pid_rusage` takes the address of the struct itself, cast to `rusage_info_t *`
/// — passing a pointer to a pointer variable makes the kernel write the whole struct
/// over that 8-byte variable and smash the stack.
func footprintBytes(_ pid: Int32) -> UInt64 {
    var ru = rusage_info_v0()
    let rc = withUnsafeMutablePointer(to: &ru) { p -> Int32 in
        p.withMemoryRebound(to: rusage_info_t?.self,
                            capacity: MemoryLayout<rusage_info_v0>.size / MemoryLayout<rusage_info_t?>.size) {
            proc_pid_rusage(pid, RUSAGE_INFO_V0, $0)
        }
    }
    return rc == 0 ? ru.ri_phys_footprint : 0
}

/// Total CPU time a process has burned since it started, in nanoseconds.
/// Two samples of this are what produce a real CPU percentage.
func cpuNanos(_ pid: Int32) -> UInt64 {
    var info = proc_taskinfo()
    let rc = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, Int32(MemoryLayout<proc_taskinfo>.size))
    return rc > 0 ? info.pti_total_user + info.pti_total_system : 0
}

/// Working directory of a process. Readable for processes we own.
func processCwd(_ pid: Int32) -> String {
    var info = proc_vnodepathinfo()
    let rc = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, Int32(MemoryLayout<proc_vnodepathinfo>.size))
    guard rc > 0 else { return "" }
    return withUnsafeBytes(of: &info.pvi_cdir.vip_path) {
        String(cString: $0.baseAddress!.assumingMemoryBound(to: CChar.self))
    }
}

func executablePath(_ pid: Int32) -> String {
    var buf = [CChar](repeating: 0, count: 4096)
    let len = proc_pidpath(pid, &buf, UInt32(buf.count))
    return len > 0 ? String(cString: buf) : ""
}

func topMemoryApps(_ procs: [ProcRecord], limit: Int = 5) -> [AppMemory] {
    var totals: [String: (bytes: UInt64, count: Int, bundle: String?)] = [:]
    for p in procs where p.rssBytes > 0 {
        let key = p.appName
        let prev = totals[key] ?? (0, 0, p.bundlePath)
        totals[key] = (prev.bytes + p.rssBytes, prev.count + 1, prev.bundle ?? p.bundlePath)
    }
    return totals
        .map { AppMemory(name: $0.key, bundlePath: $0.value.bundle, bytes: $0.value.bytes, procCount: $0.value.count) }
        .sorted { $0.bytes > $1.bytes }
        .prefix(limit)
        .map { $0 }
}

func listProcs() -> [ProcRecord] {
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
    var size = 0
    guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }

    let count = size / MemoryLayout<kinfo_proc>.stride
    var procs = [kinfo_proc](repeating: kinfo_proc(), count: count)
    var actualSize = size
    guard sysctl(&mib, 4, &procs, &actualSize, nil, 0) == 0 else { return [] }
    let actualCount = actualSize / MemoryLayout<kinfo_proc>.stride

    let now = Date().timeIntervalSince1970
    var out: [ProcRecord] = []
    out.reserveCapacity(actualCount)
    for i in 0..<actualCount {
        var kp = procs[i]
        let pid = kp.kp_proc.p_pid
        guard pid > 0 else { continue }
        let comm = withUnsafeBytes(of: &kp.kp_proc.p_comm) { raw -> String in
            String(cString: raw.baseAddress!.assumingMemoryBound(to: CChar.self))
        }
        let start = kp.kp_proc.p_un.__p_starttime
        let startEpoch = Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000
        let ageHours = max(0, (now - startEpoch) / 3600)
        let footprint = footprintBytes(pid)
        var rec = ProcRecord(id: pid, pid: pid, ppid: kp.kp_eproc.e_ppid, comm: comm,
                             ageHours: ageHours, cpuNanos: cpuNanos(pid),
                             rssBytes: footprint,
                             path: footprint > 0 ? executablePath(pid) : "")
        rec.isZombie = kp.kp_proc.p_stat == Int8(SZOMB)
        out.append(rec)
    }
    return out
}

/// Walk the parent chain of `pid` so cleanup never touches this app's own shell lineage.
func ancestorPids(of pid: Int32, procs: [ProcRecord]) -> Set<Int32> {
    let byPid = Dictionary(uniqueKeysWithValues: procs.map { ($0.pid, $0.ppid) })
    var result: Set<Int32> = []
    var current = pid
    while current > 1, let parent = byPid[current], !result.contains(current) {
        result.insert(current)
        current = parent
    }
    return result
}

func formatBytes(_ bytes: UInt64) -> String {
    let gb = Double(bytes) / 1_073_741_824
    return gb >= 1 ? String(format: "%.1f GB", gb) : String(format: "%.0f MB", Double(bytes) / 1_048_576)
}

func formatMB(_ mb: Double) -> String {
    mb >= 1024 ? String(format: "%.1f GB", mb / 1024) : String(format: "%.0f MB", mb)
}

func diskFreeGB() -> Double {
    let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey]
    guard let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys),
          let bytes = values.volumeAvailableCapacityForImportantUsage else { return 0 }
    return Double(bytes) / 1_073_741_824
}

// MARK: - Health model

final class HealthMonitor: ObservableObject {
    @Published var uptimeDaysValue: Double = 0
    @Published var loadAvg: String = "-"
    @Published var swapUsedMB: Double = 0
    @Published var swapTotalMB: Double = 0
    @Published var availableMemPercent: Int = 100
    @Published var totalRAMGB: Double = physicalMemoryGB()
    @Published var jamfCPU: Double = 0
    @Published var idleShells: [ProcRecord] = []
    @Published var staleAgents: [ProcRecord] = []
    @Published var zombies: [ProcRecord] = []
    @Published var topProcessName: String = "-"
    @Published var topProcessCPU: Double = 0
    @Published var topApps: [AppMemory] = []
    @Published var diskFreeGBValue: Double = 0
    @Published var lastChecked: Date = Date()
    @Published var shellsKilledThisSession = 0
    @Published var agentsKilledThisSession = 0

    private var timer: Timer?
    private var currentInterval: TimeInterval = 0
    private var prevCPUNanos: [Int32: UInt64] = [:]
    private var prevCPUSample: Date?
    private let defaults = UserDefaults.standard
    private let selfPid = getpid()

    var swapUsedPercent: Double { swapTotalMB > 0 ? (swapUsedMB / swapTotalMB) * 100 : 0 }
    var uptimeBad: Bool { uptimeDaysValue >= 7 }
    var swapBad: Bool { swapUsedPercent >= 70 }
    var memBad: Bool { availableMemPercent < 15 }
    var shellsBad: Bool { idleShells.count > 20 }
    var jamfBad: Bool { jamfCPU >= 20 }
    var diskBad: Bool { diskFreeGBValue < 10 }
    var anyBad: Bool { uptimeBad || swapBad || memBad || shellsBad || jamfBad || diskBad }

    /// Short glanceable tag for the menu-bar icon when something needs attention.
    var badgeText: String? {
        if uptimeBad { return "\(Int(uptimeDaysValue))d" }
        if swapBad { return "SWAP" }
        if memBad { return "MEM" }
        if diskBad { return "DISK" }
        if jamfBad { return "JAMF" }
        if shellsBad { return "SHELLS" }
        return nil
    }

    func start() {
        refresh()
        // CPU% needs two samples; without this every row reads 0% for the first 10 minutes.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.refresh() }
        scheduleTimer(interval: 600)
    }

    /// Checks less often while healthy, more often while something's flagged —
    /// same near-zero cost per check either way, just tuned to how urgent it is.
    private func scheduleTimer(interval: TimeInterval) {
        guard interval != currentInterval else { return }
        currentInterval = interval
        timer?.invalidate()
        let t = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        t.tolerance = interval * 0.1 // let the OS coalesce this wake with others
        timer = t
    }

    /// Runs synchronously on the calling thread (Timer fires on the main run loop).
    /// These are all direct syscalls now — a full pass over ~1000 processes takes low
    /// single-digit milliseconds, so there's nothing here worth a background queue hop.
    /// (A background `.utility` queue was tried and dropped: on an `LSUIElement`
    /// menu-bar-only app with no visible window, App Nap throttled that queue hard
    /// enough that refresh() never ran at all.)
    func refresh() {
        let days = uptimeDays()
        let load = loadAvgString()
        let swap = swapInfo()
        let memPct = availableMemoryPercent()
        let procs = withCPUPercent(listProcs())
        let ancestors = ancestorPids(of: selfPid, procs: procs)

        let jamf = procs.first { $0.comm == "JamfDaemon" }?.cpuPercent ?? 0
        let shells = describe(procs
            .filter { !$0.isZombie && ($0.comm == "zsh" || $0.comm == "bash") && $0.ageHours >= 6 && !ancestors.contains($0.pid) }
            .sorted { $0.ageHours > $1.ageHours }, in: procs)
        let agents = describe(procs
            .filter { !$0.isZombie && $0.comm.lowercased().contains("claude") && $0.ageHours >= 24 && !ancestors.contains($0.pid) }
            .sorted { $0.ageHours > $1.ageHours }, in: procs)
        let dead = describe(procs.filter { $0.isZombie && $0.ageHours >= 1 }
            .sorted { $0.ageHours > $1.ageHours }, in: procs)
        let top = procs
            .filter { $0.pid != selfPid && $0.comm != "kernel_task" }
            .max { $0.cpuPercent < $1.cpuPercent }
        let apps = topMemoryApps(procs)

        uptimeDaysValue = days
        loadAvg = load
        swapUsedMB = swap.usedMB
        swapTotalMB = swap.totalMB
        availableMemPercent = memPct
        jamfCPU = jamf
        idleShells = shells
        staleAgents = agents
        zombies = dead
        topProcessName = top?.appName ?? "-"
        topProcessCPU = top?.cpuPercent ?? 0
        topApps = apps
        diskFreeGBValue = diskFreeGB()
        lastChecked = Date()
        maybeNotify()
        scheduleTimer(interval: anyBad ? 60 : 600)
    }

    /// Attach the working directory and the owning app to the processes we're about to
    /// offer to kill. A shell whose parent is launchd has outlived whatever started it.
    private func describe(_ subset: [ProcRecord], in all: [ProcRecord]) -> [ProcRecord] {
        let names = Dictionary(all.map { ($0.pid, $0.appName) }, uniquingKeysWith: { a, _ in a })
        let kids = Dictionary(grouping: all, by: \.ppid)
        return subset.map { p in
            var q = p
            q.cwd = processCwd(p.pid)
            q.children = (kids[p.pid] ?? []).map(\.appName)
            q.childCPU = (kids[p.pid] ?? []).reduce(0) { $0 + $1.cpuPercent }
            let parent = names[p.ppid] ?? ""
            q.owner = (parent == "launchd" || parent.isEmpty) ? "orphan" : parent
            return q
        }
    }

    /// CPU percent = CPU time burned since the last refresh / wall time elapsed.
    /// Can exceed 100% for a multithreaded process, same as Activity Monitor.
    /// The first sample after launch has no baseline, so everything reads 0%.
    private func withCPUPercent(_ procs: [ProcRecord]) -> [ProcRecord] {
        let now = Date()
        let elapsed = prevCPUSample.map { now.timeIntervalSince($0) } ?? 0
        var out = procs
        if elapsed > 0.5 {
            let elapsedNanos = elapsed * 1_000_000_000
            for i in out.indices {
                guard let prev = prevCPUNanos[out[i].pid], out[i].cpuNanos > prev else { continue }
                out[i].cpuPercent = Double(out[i].cpuNanos - prev) / elapsedNanos * 100
            }
        }
        prevCPUNanos = Dictionary(procs.map { ($0.pid, $0.cpuNanos) }, uniquingKeysWith: { a, _ in a })
        prevCPUSample = now
        return out
    }

    private func maybeNotify() {
        checkRule("uptime", uptimeBad, "Reboot recommended", "Mac has been up \(Int(uptimeDaysValue)) days.")
        checkRule("swap", swapBad, "Swap pressure high", "Swap used \(Int(swapUsedPercent))% — consider closing apps or rebooting.")
        checkRule("mem", memBad, "Memory pressure high", "Only \(availableMemPercent)% available — things may slow down or get killed.")
        checkRule("shells", shellsBad, "Idle shells piling up", "\(idleShells.count) idle shell processes — clean up in Mac Health.")
        checkRule("jamf", jamfBad, "Jamf using high CPU", "JamfDaemon at \(Int(jamfCPU))% — may need a reboot.")
        checkRule("disk", diskBad, "Disk space low", "Only \(String(format: "%.1f", diskFreeGBValue))GB free on the boot volume.")
        weeklyDigest()
    }

    private func checkRule(_ key: String, _ bad: Bool, _ title: String, _ body: String) {
        guard bad else { return }
        let lastKey = "lastNotified.\(key)"
        let last = defaults.double(forKey: lastKey)
        let now = Date().timeIntervalSince1970
        if now - last > 24 * 3600 {
            notify(title, body)
            defaults.set(now, forKey: lastKey)
        }
    }

    private func weeklyDigest() {
        let lastKey = "lastWeeklyDigest"
        let last = defaults.double(forKey: lastKey)
        let now = Date().timeIntervalSince1970
        if now - last > 7 * 24 * 3600 {
            notify("Weekly Mac health check",
                   "Uptime \(Int(uptimeDaysValue))d, swap \(Int(swapUsedPercent))%, \(idleShells.count) idle shells, \(staleAgents.count) stale agent sessions.")
            defaults.set(now, forKey: lastKey)
        }
    }

    /// Shells with a running child or CPU are doing something; only the truly idle ones are cleanup targets.
    var killableShells: [ProcRecord] { idleShells.filter { !$0.isActive } }

    func killIdleShells() {
        let targets = killableShells
        shellsKilledThisSession += targets.count
        // SIGHUP, not SIGTERM: interactive zsh/bash ignore SIGTERM; SIGHUP is what closing a terminal sends.
        for p in targets { kill(p.pid, SIGHUP) }
        refresh()
    }

    func killStaleAgents() {
        agentsKilledThisSession += staleAgents.count
        for p in staleAgents { kill(p.pid, SIGTERM) }
        refresh()
    }

    func rebootNow() {
        shell("/usr/bin/osascript", ["-e", "tell application \"System Events\" to restart"])
    }
}

// MARK: - UI

private let cardBG = Color.primary.opacity(0.05)

struct Card<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.caption2)
                Text(title).font(.caption).fontWeight(.semibold).textCase(.uppercase)
            }
            .foregroundColor(.secondary)
            content
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(cardBG))
    }
}

struct StatRow: View {
    let label: String
    let value: String
    let bad: Bool
    var hint: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack {
                Text(label).foregroundColor(.secondary)
                Spacer()
                Text(value).fontWeight(.medium).monospacedDigit()
                    .foregroundColor(bad ? .red : .primary)
            }
            if let hint {
                Text(hint).font(.caption2).foregroundColor(.secondary)
            }
        }
        .font(.callout)
    }
}

/// Horizontal fill bar — turns a bare percentage into something readable at a glance.
struct MeterBar: View {
    let fraction: Double
    let bad: Bool
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12))
                Capsule().fill(bad ? Color.red : Color.accentColor)
                    .frame(width: max(2, geo.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: 5)
    }
}

struct AppMemRow: View {
    let app: AppMemory
    let maxBytes: UInt64
    var body: some View {
        HStack(spacing: 7) {
            if let icon = appIcon(for: app.bundlePath) {
                Image(nsImage: icon).resizable().frame(width: 16, height: 16)
            } else {
                Image(systemName: "terminal").font(.caption)
                    .frame(width: 16, height: 16).foregroundColor(.secondary)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(app.name).lineLimit(1).truncationMode(.middle)
                    if app.procCount > 1 {
                        Text("×\(app.procCount)").font(.caption2).foregroundColor(.secondary)
                    }
                    Spacer()
                    Text(formatBytes(app.bytes)).monospacedDigit().foregroundColor(.secondary)
                }
                .font(.callout)
                MeterBar(fraction: maxBytes > 0 ? Double(app.bytes) / Double(maxBytes) : 0, bad: false)
            }
        }
    }
}

struct ProcListView: View {
    let title: String
    let procs: [ProcRecord]
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        if !procs.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(procs.prefix(4)) { p in
                    HStack(spacing: 4) {
                        Text(p.contextLabel).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 4)
                        Text("\(String(p.pid)) · \(Int(p.ageHours))h").monospacedDigit()
                    }
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .help(p.cwd.isEmpty ? p.comm : p.cwd)
                }
                if procs.count > 4 {
                    Text("+ \(procs.count - 4) more").font(.caption2).foregroundColor(.secondary)
                }
                Button("See all sessions…") {
                    openWindow(id: "sessions")
                    NSApp.activate(ignoringOtherApps: true) // menu-bar-only app: window opens behind otherwise
                }
                .buttonStyle(.link).font(.caption2)
            }
        }
    }
}

struct MenuContent: View {
    @ObservedObject var monitor: HealthMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: monitor.anyBad ? "exclamationmark.triangle.fill" : "heart.fill")
                    .foregroundColor(monitor.anyBad ? .orange : .pink)
                Text("Mac Health").font(.headline)
                Spacer()
                Button { monitor.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("Refresh now")
            }

            Card(title: "System", icon: "cpu") {
                StatRow(label: "Uptime", value: "\(Int(monitor.uptimeDaysValue)) days", bad: monitor.uptimeBad)
                StatRow(label: "Load avg", value: monitor.loadAvg, bad: false)
                StatRow(label: "Disk free", value: "\(String(format: "%.0f", monitor.diskFreeGBValue))GB", bad: monitor.diskBad)
                if monitor.topProcessCPU >= 1 {
                    StatRow(label: "Busiest app", value: "\(monitor.topProcessName) \(Int(monitor.topProcessCPU))% CPU", bad: false)
                }
                if monitor.jamfCPU > 0 || monitor.jamfBad {
                    StatRow(label: "Jamf (MDM) CPU", value: "\(Int(monitor.jamfCPU))%", bad: monitor.jamfBad)
                }
            }

            Card(title: "Memory", icon: "memorychip") {
                StatRow(label: "Available",
                        value: "\(monitor.availableMemPercent)% of \(String(format: "%.0f", monitor.totalRAMGB))GB",
                        bad: monitor.memBad)
                MeterBar(fraction: Double(100 - monitor.availableMemPercent) / 100, bad: monitor.memBad)
                StatRow(label: "Swap",
                        value: "\(formatMB(monitor.swapUsedMB)) / \(formatMB(monitor.swapTotalMB))",
                        bad: monitor.swapBad,
                        hint: monitor.swapUsedPercent >= 50
                            ? "macOS reuses swap files — only a reboot actually clears this."
                            : nil)
                MeterBar(fraction: monitor.swapUsedPercent / 100, bad: monitor.swapBad)
            }

            if !monitor.topApps.isEmpty {
                Card(title: "Memory by app", icon: "square.stack.3d.up") {
                    ForEach(monitor.topApps) { app in
                        AppMemRow(app: app, maxBytes: monitor.topApps.first?.bytes ?? 0)
                    }
                    Text("Memory footprint, helper processes rolled up. Swap is not attributable per app.")
                        .font(.caption2).foregroundColor(.secondary)
                }
            }

            Card(title: "Cleanup", icon: "trash") {
                StatRow(label: "Idle shells", value: "\(monitor.idleShells.count)", bad: monitor.shellsBad)
                ProcListView(title: "Idle shells", procs: monitor.idleShells)
                StatRow(label: "Stale agent sessions", value: "\(monitor.staleAgents.count)", bad: !monitor.staleAgents.isEmpty)
                ProcListView(title: "Stale agents", procs: monitor.staleAgents)

                HStack {
                    ConfirmButton(title: "Kill shells (\(monitor.killableShells.count))", confirmTitle: "Terminate \(monitor.killableShells.count)?") { monitor.killIdleShells() }
                        .disabled(monitor.killableShells.isEmpty)
                    ConfirmButton(title: "Kill agents (\(monitor.staleAgents.count))", confirmTitle: "Terminate \(monitor.staleAgents.count)?") { monitor.killStaleAgents() }
                        .disabled(monitor.staleAgents.isEmpty)
                }
                .controlSize(.small)

                if monitor.shellsKilledThisSession > 0 || monitor.agentsKilledThisSession > 0 {
                    Text("Cleaned \(monitor.shellsKilledThisSession) shells, \(monitor.agentsKilledThisSession) agents this session")
                        .font(.caption2).foregroundColor(.secondary)
                }
            }

            HStack {
                ConfirmButton(title: "Reboot now", confirmTitle: "Reboot?") { monitor.rebootNow() }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
            .controlSize(.small)

            Text("Checked \(monitor.lastChecked.formatted(date: .omitted, time: .standard))")
                .font(.caption2).foregroundColor(.secondary)
        }
        .padding(12)
        .frame(width: 320)
    }
}

struct SessionsView: View {
    @ObservedObject var monitor: HealthMonitor

    private func section(_ title: String, _ procs: [ProcRecord]) -> some View {
        Section {
            ForEach(procs.sorted { ($0.isActive ? 0 : 1, -$0.ageHours) < ($1.isActive ? 0 : 1, -$1.ageHours) }) { p in
                HStack(alignment: .top, spacing: 8) {
                    Circle().fill(p.isActive ? Color.green : Color.gray.opacity(0.5))
                        .frame(width: 8, height: 8).padding(.top, 5)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(p.contextLabel).font(.body)
                        Text(p.cwd.isEmpty ? "unknown folder" : p.cwd)
                            .font(.caption).foregroundColor(.secondary)
                            .lineLimit(1).truncationMode(.head).textSelection(.enabled)
                        if !p.children.isEmpty {
                            Text("running: " + p.children.joined(separator: ", "))
                                .font(.caption).foregroundColor(.green).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 1) {
                        Text("pid \(String(p.pid)) · \(Int(p.ageHours))h")
                        Text(String(format: "CPU %.1f%%", p.cpuPercent)
                             + (p.childCPU > 0 ? String(format: " (+%.1f%% children)", p.childCPU) : "")
                             + " · " + formatBytes(p.rssBytes))
                    }
                    .font(.caption).monospacedDigit().foregroundColor(.secondary)
                }
            }
        } header: {
            let active = procs.filter(\.isActive).count
            Text("\(title) — \(procs.count) total, \(active) active").font(.headline)
        }
    }

    var body: some View {
        List {
            section("Idle shells", monitor.idleShells)
            section("Stale agent sessions", monitor.staleAgents)
            if !monitor.zombies.isEmpty {
                Section {
                    ForEach(monitor.zombies) { p in
                        HStack {
                            Text("\(p.comm) · pid \(String(p.pid)) · \(Int(p.ageHours))h")
                            Spacer()
                            Text("parent: \(p.owner) (pid \(String(p.ppid)))")
                        }
                        .font(.caption).foregroundColor(.secondary)
                    }
                } header: {
                    Text("Zombies — \(monitor.zombies.count), already dead").font(.headline)
                } footer: {
                    Text("Exited but never reaped by the parent, so no folder or memory is left. Can't be killed; they go away when the parent exits.")
                        .font(.caption2).foregroundColor(.secondary)
                }
            }
        }
        .frame(minWidth: 560, minHeight: 420)
        .overlay(alignment: .bottom) {
            Text("Active = has a running child process or ≥1% CPU since the last check.")
                .font(.caption2).foregroundColor(.secondary).padding(4)
        }
    }
}

// Inline two-step confirm: system dialogs steal focus and close the MenuBarExtra window.
struct ConfirmButton: View {
    let title: String
    let confirmTitle: String
    let action: () -> Void
    @State private var armed = false

    var body: some View {
        if armed {
            HStack(spacing: 4) {
                Button(confirmTitle) { armed = false; action() }.tint(.red)
                Button("Cancel") { armed = false }
            }
        } else {
            Button(title) { armed = true }
        }
    }
}

@main
struct MacHealthApp: App {
    @StateObject private var monitor = HealthMonitor()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(monitor: monitor)
        } label: {
            HStack(spacing: 3) {
                Image(systemName: monitor.anyBad ? "exclamationmark.triangle.fill" : "heart.fill")
                if let badge = monitor.badgeText {
                    Text(badge)
                }
            }
        }
        .menuBarExtraStyle(.window)

        Window("Sessions", id: "sessions") {
            SessionsView(monitor: monitor)
        }
    }

    init() {
        _monitor.wrappedValue.start()
    }
}
