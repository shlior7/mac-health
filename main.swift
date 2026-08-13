import SwiftUI
import Darwin

// MARK: - Shell helper

func shell(_ launchPath: String, _ args: [String]) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: launchPath)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = Pipe()
    do {
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    } catch { return "" }
}

func notify(_ title: String, _ body: String) {
    _ = shell("/usr/bin/osascript", ["-e",
        "display notification \"\(body)\" with title \"\(title)\""])
}

// MARK: - Process record

struct ProcRecord: Identifiable {
    let id: Int32
    let pid: Int32
    let etime: String
    let cpu: Double
    let comm: String
    let ageHours: Double

    init(pid: Int32, etime: String, cpu: Double, comm: String) {
        self.id = pid
        self.pid = pid
        self.etime = etime
        self.cpu = cpu
        self.comm = comm
        self.ageHours = ProcRecord.parseAgeHours(etime)
    }

    static func parseAgeHours(_ etime: String) -> Double {
        // formats: "mm:ss", "hh:mm:ss", "dd-hh:mm:ss"
        var days = 0.0
        var rest = etime
        if let dashIdx = etime.firstIndex(of: "-") {
            days = Double(etime[etime.startIndex..<dashIdx]) ?? 0
            rest = String(etime[etime.index(after: dashIdx)...])
        }
        let parts = rest.split(separator: ":").compactMap { Double($0) }
        var hours = days * 24
        if parts.count == 3 {
            hours += parts[0] + parts[1] / 60
        } else if parts.count == 2 {
            hours += parts[1] / 3600 // mm:ss -> negligible hours
        }
        return hours
    }
}

func listProcs() -> [ProcRecord] {
    let out = shell("/bin/ps", ["-eo", "pid,etime,pcpu,comm"])
    var records: [ProcRecord] = []
    for line in out.split(separator: "\n").dropFirst() {
        let fields = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard fields.count >= 4, let pid = Int32(fields[0]), let cpu = Double(fields[2]) else { continue }
        let comm = fields[3...].joined(separator: " ")
        records.append(ProcRecord(pid: pid, etime: fields[1], cpu: cpu, comm: comm))
    }
    return records
}

// MARK: - Health model

final class HealthMonitor: ObservableObject {
    @Published var uptimeDays: Double = 0
    @Published var loadAvg: String = "-"
    @Published var swapUsedMB: Double = 0
    @Published var swapTotalMB: Double = 0
    @Published var memFreePercent: Int = 100
    @Published var jamfCPU: Double = 0
    @Published var idleShells: [ProcRecord] = []
    @Published var staleAgents: [ProcRecord] = []
    @Published var lastChecked: Date = Date()

    private var timer: Timer?
    private let defaults = UserDefaults.standard

    var swapUsedPercent: Double { swapTotalMB > 0 ? (swapUsedMB / swapTotalMB) * 100 : 0 }
    var uptimeBad: Bool { uptimeDays >= 7 }
    var swapBad: Bool { swapUsedPercent >= 70 }
    var memBad: Bool { memFreePercent < 15 }
    var shellsBad: Bool { idleShells.count > 20 }
    var jamfBad: Bool { jamfCPU >= 20 }
    var anyBad: Bool { uptimeBad || swapBad || memBad || shellsBad || jamfBad }

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func refresh() {
        DispatchQueue.global(qos: .background).async { [weak self] in
            guard let self else { return }
            let up = shell("/usr/bin/uptime", [])
            let days = HealthMonitor.parseUptimeDays(up)
            let load = HealthMonitor.parseLoad(up)

            let swap = shell("/usr/sbin/sysctl", ["vm.swapusage"])
            let (used, total) = HealthMonitor.parseSwap(swap)

            let pressure = shell("/usr/bin/memory_pressure", [])
            let freePct = HealthMonitor.parseFreePercent(pressure)

            let procs = listProcs()
            let jamf = procs.first { $0.comm.contains("JamfDaemon") }?.cpu ?? 0
            let shells = procs.filter { $0.comm == "zsh" || $0.comm == "bash" }
                .sorted { $0.ageHours > $1.ageHours }
            let agents = procs.filter { $0.comm.lowercased().contains("claude") && $0.ageHours >= 24 }
                .sorted { $0.ageHours > $1.ageHours }

            DispatchQueue.main.async {
                self.uptimeDays = days
                self.loadAvg = load
                self.swapUsedMB = used
                self.swapTotalMB = total
                self.memFreePercent = freePct
                self.jamfCPU = jamf
                self.idleShells = shells
                self.staleAgents = agents
                self.lastChecked = Date()
                self.maybeNotify()
            }
        }
    }

    private func maybeNotify() {
        checkRule("uptime", uptimeBad, "Reboot recommended", "Mac has been up \(Int(uptimeDays)) days.")
        checkRule("swap", swapBad, "Swap pressure high", "Swap used \(Int(swapUsedPercent))% — consider closing apps or rebooting.")
        checkRule("mem", memBad, "Memory pressure high", "Only \(memFreePercent)% free — things may slow down or get killed.")
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
                   "Uptime \(Int(uptimeDays))d, swap \(Int(swapUsedPercent))%, \(idleShells.count) idle shells, \(staleAgents.count) stale agent sessions.")
            defaults.set(now, forKey: lastKey)
        }
    }

    func killIdleShells() {
        for p in idleShells { kill(p.pid, SIGTERM) }
        refresh()
    }

    func killStaleAgents() {
        for p in staleAgents { kill(p.pid, SIGTERM) }
        refresh()
    }

    func rebootNow() {
        _ = shell("/usr/bin/osascript", ["-e", "tell application \"System Events\" to restart"])
    }

    // MARK: parsing

    static func parseUptimeDays(_ s: String) -> Double {
        if let range = s.range(of: #"up (\d+) day"#, options: .regularExpression) {
            let numStr = s[range].filter(\.isNumber)
            return Double(numStr) ?? 0
        }
        return 0
    }

    static func parseLoad(_ s: String) -> String {
        if let range = s.range(of: #"load averages?: .*"#, options: .regularExpression) {
            return String(s[range])
        }
        return "-"
    }

    static func parseSwap(_ s: String) -> (Double, Double) {
        func extract(_ label: String) -> Double {
            guard let r = s.range(of: "\(label) = ([0-9.]+)M", options: .regularExpression) else { return 0 }
            let match = String(s[r])
            let num = match.replacingOccurrences(of: "\(label) = ", with: "").replacingOccurrences(of: "M", with: "")
            return Double(num) ?? 0
        }
        return (extract("used"), extract("total"))
    }

    static func parseFreePercent(_ s: String) -> Int {
        if let r = s.range(of: #"free percentage: (\d+)%"#, options: .regularExpression) {
            let num = String(s[r]).filter(\.isNumber)
            return Int(num) ?? 100
        }
        return 100
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

struct MenuContent: View {
    @ObservedObject var monitor: HealthMonitor
    @State private var confirmShells = false
    @State private var confirmAgents = false
    @State private var confirmReboot = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Mac Health").font(.headline)

            StatRow(label: "Uptime", value: "\(Int(monitor.uptimeDays)) days", bad: monitor.uptimeBad)
            StatRow(label: "Load avg", value: monitor.loadAvg, bad: false)
            StatRow(label: "Swap", value: "\(Int(monitor.swapUsedMB))MB / \(Int(monitor.swapTotalMB))MB", bad: monitor.swapBad)
            StatRow(label: "Free memory", value: "\(monitor.memFreePercent)%", bad: monitor.memBad)
            StatRow(label: "Jamf CPU", value: "\(Int(monitor.jamfCPU))%", bad: monitor.jamfBad)
            StatRow(label: "Idle shells", value: "\(monitor.idleShells.count)", bad: monitor.shellsBad)
            StatRow(label: "Stale agent sessions", value: "\(monitor.staleAgents.count)", bad: !monitor.staleAgents.isEmpty)

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
