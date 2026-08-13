import SwiftUI
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
    let cpuPercent: Double
}

private let FSCALE = 2048.0 // from <sys/param.h>, stable BSD constant

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
        let cpuPercent = Double(kp.kp_proc.p_pctcpu) / FSCALE * 100
        out.append(ProcRecord(id: pid, pid: pid, ppid: kp.kp_eproc.e_ppid, comm: comm,
                               ageHours: ageHours, cpuPercent: cpuPercent))
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

func formatMB(_ mb: Double) -> String {
    mb >= 1024 ? String(format: "%.1f GB", mb / 1024) : String(format: "%.0f MB", mb)
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
    @Published var lastChecked: Date = Date()
    @Published var shellsKilledThisSession = 0
    @Published var agentsKilledThisSession = 0

    private var timer: Timer?
    private let defaults = UserDefaults.standard
    private let selfPid = getpid()

    var swapUsedPercent: Double { swapTotalMB > 0 ? (swapUsedMB / swapTotalMB) * 100 : 0 }
    var uptimeBad: Bool { uptimeDaysValue >= 7 }
    var swapBad: Bool { swapUsedPercent >= 70 }
    var memBad: Bool { availableMemPercent < 15 }
    var shellsBad: Bool { idleShells.count > 20 }
    var jamfBad: Bool { jamfCPU >= 20 }
    var anyBad: Bool { uptimeBad || swapBad || memBad || shellsBad || jamfBad }

    func start() {
        refresh()
        // Native syscalls only — this timer costs microseconds per tick, safe at 5 min.
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func refresh() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let days = uptimeDays()
            let load = loadAvgString()
            let swap = swapInfo()
            let memPct = availableMemoryPercent()
            let procs = listProcs()
            let ancestors = ancestorPids(of: self.selfPid, procs: procs)

            let jamf = procs.first { $0.comm == "JamfDaemon" }?.cpuPercent ?? 0
            let shells = procs
                .filter { ($0.comm == "zsh" || $0.comm == "bash") && $0.ageHours >= 6 && !ancestors.contains($0.pid) }
                .sorted { $0.ageHours > $1.ageHours }
            let agents = procs
                .filter { $0.comm.lowercased().contains("claude") && $0.ageHours >= 24 && !ancestors.contains($0.pid) }
                .sorted { $0.ageHours > $1.ageHours }

            DispatchQueue.main.async {
                self.uptimeDaysValue = days
                self.loadAvg = load
                self.swapUsedMB = swap.usedMB
                self.swapTotalMB = swap.totalMB
                self.availableMemPercent = memPct
                self.jamfCPU = jamf
                self.idleShells = shells
                self.staleAgents = agents
                self.lastChecked = Date()
                self.maybeNotify()
            }
        }
    }

    private func maybeNotify() {
        checkRule("uptime", uptimeBad, "Reboot recommended", "Mac has been up \(Int(uptimeDaysValue)) days.")
        checkRule("swap", swapBad, "Swap pressure high", "Swap used \(Int(swapUsedPercent))% — consider closing apps or rebooting.")
        checkRule("mem", memBad, "Memory pressure high", "Only \(availableMemPercent)% available — things may slow down or get killed.")
        checkRule("shells", shellsBad, "Idle shells piling up", "\(idleShells.count) idle shell processes — clean up in Mac Health.")
        checkRule("jamf", jamfBad, "Jamf using high CPU", "JamfDaemon at \(Int(jamfCPU))% — may need a reboot.")
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

    func killIdleShells() {
        shellsKilledThisSession += idleShells.count
        for p in idleShells { kill(p.pid, SIGTERM) }
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

struct StatRow: View {
    let label: String
    let value: String
    let bad: Bool
    var body: some View {
        HStack {
            Text(label).foregroundColor(.secondary)
            Spacer()
            Text(value).fontWeight(.medium).foregroundColor(bad ? .red : .primary)
        }
    }
}

struct ProcListView: View {
    let title: String
    let procs: [ProcRecord]
    var body: some View {
        if !procs.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption).foregroundColor(.secondary)
                ForEach(procs.prefix(5)) { p in
                    Text("PID \(p.pid) · \(String(format: "%.1f", p.ageHours))h old")
                        .font(.caption2).foregroundColor(.secondary)
                }
                if procs.count > 5 {
                    Text("+ \(procs.count - 5) more").font(.caption2).foregroundColor(.secondary)
                }
            }
        }
    }
}

struct MenuContent: View {
    @ObservedObject var monitor: HealthMonitor
    @State private var confirmShells = false
    @State private var confirmAgents = false
    @State private var confirmReboot = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Mac Health").font(.headline)

            StatRow(label: "Uptime", value: "\(Int(monitor.uptimeDaysValue)) days", bad: monitor.uptimeBad)
            StatRow(label: "Load avg", value: monitor.loadAvg, bad: false)
            StatRow(label: "Swap", value: "\(formatMB(monitor.swapUsedMB)) / \(formatMB(monitor.swapTotalMB))", bad: monitor.swapBad)
            StatRow(label: "Available memory", value: "\(monitor.availableMemPercent)% of \(String(format: "%.0f", monitor.totalRAMGB))GB", bad: monitor.memBad)
            StatRow(label: "Jamf CPU", value: "\(Int(monitor.jamfCPU))%", bad: monitor.jamfBad)
            StatRow(label: "Idle shells", value: "\(monitor.idleShells.count)", bad: monitor.shellsBad)
            StatRow(label: "Stale agent sessions", value: "\(monitor.staleAgents.count)", bad: !monitor.staleAgents.isEmpty)

            ProcListView(title: "Idle shells", procs: monitor.idleShells)
            ProcListView(title: "Stale agents", procs: monitor.staleAgents)

            Divider()

            Button("Clean up idle shells (\(monitor.idleShells.count))") { confirmShells = true }
                .disabled(monitor.idleShells.isEmpty)
                .confirmationDialog("Terminate \(monitor.idleShells.count) idle shell processes?", isPresented: $confirmShells) {
                    Button("Terminate", role: .destructive) { monitor.killIdleShells() }
                }

            Button("Clean up stale agent sessions (\(monitor.staleAgents.count))") { confirmAgents = true }
                .disabled(monitor.staleAgents.isEmpty)
                .confirmationDialog("Terminate \(monitor.staleAgents.count) stale Claude/agent sessions?", isPresented: $confirmAgents) {
                    Button("Terminate", role: .destructive) { monitor.killStaleAgents() }
                }

            Button("Reboot now") { confirmReboot = true }
                .confirmationDialog("Reboot this Mac now?", isPresented: $confirmReboot) {
                    Button("Reboot", role: .destructive) { monitor.rebootNow() }
                }

            if monitor.shellsKilledThisSession > 0 || monitor.agentsKilledThisSession > 0 {
                Text("Cleaned up \(monitor.shellsKilledThisSession) shells, \(monitor.agentsKilledThisSession) agents this session")
                    .font(.caption2).foregroundColor(.secondary)
            }

            Divider()
            Button("Refresh") { monitor.refresh() }
            Text("Checked \(monitor.lastChecked.formatted(date: .omitted, time: .standard))")
                .font(.caption).foregroundColor(.secondary)

            Button("Quit Mac Health") { NSApplication.shared.terminate(nil) }
        }
        .padding(12)
        .frame(width: 300)
    }
}

@main
struct MacHealthApp: App {
    @StateObject private var monitor = HealthMonitor()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(monitor: monitor)
        } label: {
            Image(systemName: monitor.anyBad ? "exclamationmark.triangle.fill" : "heart.fill")
        }
        .menuBarExtraStyle(.window)
    }

    init() {
        _monitor.wrappedValue.start()
    }
}
