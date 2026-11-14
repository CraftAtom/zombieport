import Combine
import Darwin
import Foundation
import IOKit

// MARK: - Temperature

// macOS has no public API for CPU or SSD temperature without root. These private IOKit
// functions read the same HID temperature sensors that tools such as `powermetrics` and
// other menu bar monitors use, and they need no entitlement. The interface is undocumented,
// so a future macOS release can change or remove it. Every call here degrades to "no
// reading" (nil), never to a stale or zero value.
@_silgen_name("IOHIDEventSystemClientCreate")
private func IOHIDEventSystemClientCreate(_ allocator: CFAllocator?) -> Unmanaged<AnyObject>
@_silgen_name("IOHIDEventSystemClientSetMatching")
private func IOHIDEventSystemClientSetMatching(_ client: AnyObject, _ matching: CFDictionary)
@_silgen_name("IOHIDEventSystemClientCopyServices")
private func IOHIDEventSystemClientCopyServices(_ client: AnyObject) -> Unmanaged<CFArray>?
@_silgen_name("IOHIDServiceClientCopyProperty")
private func IOHIDServiceClientCopyProperty(_ service: AnyObject, _ key: CFString) -> Unmanaged<CFTypeRef>?
@_silgen_name("IOHIDServiceClientCopyEvent")
private func IOHIDServiceClientCopyEvent(_ service: AnyObject, _ type: Int64, _ options: Int32, _ timeout: Int64) -> Unmanaged<AnyObject>?
@_silgen_name("IOHIDEventGetFloatValue")
private func IOHIDEventGetFloatValue(_ event: AnyObject, _ field: Int32) -> Double

struct Temperatures: Equatable {
    /// Hottest CPU die sensor, in degrees Celsius.
    var cpuMax: Double?
    /// Average of the valid CPU die sensors.
    var cpuAverage: Double?
    /// Solid-state drive (NAND) sensor.
    var ssd: Double?
}

enum TemperatureReader {
    /// Readings outside this range come from broken sensors (one sensor reports about -9200).
    static let validRange: ClosedRange<Double> = 0...130

    /// The shared HID client, created once. It stays nil when the interface is unavailable.
    private static let client: AnyObject? = {
        let client = IOHIDEventSystemClientCreate(kCFAllocatorDefault).takeRetainedValue()
        // Usage page 0xff00, usage 5: Apple vendor temperature sensors.
        IOHIDEventSystemClientSetMatching(client, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary)
        return client
    }()

    /// Reads every temperature sensor as (name, degrees Celsius).
    static func readSensors() -> [(name: String, value: Double)] {
        guard let client, let services = IOHIDEventSystemClientCopyServices(client)?.takeRetainedValue() as [AnyObject]? else {
            return []
        }
        var readings: [(String, Double)] = []
        for service in services {
            autoreleasepool {
                let name = IOHIDServiceClientCopyProperty(service, "Product" as CFString)?.takeRetainedValue() as? String ?? ""
                // Event type 15 is a temperature event, and its value is in field 15 << 16.
                guard let event = IOHIDServiceClientCopyEvent(service, 15, 0, 0)?.takeRetainedValue() else { return }
                readings.append((name, IOHIDEventGetFloatValue(event, 15 << 16)))
            }
        }
        return readings
    }

    static func read() -> Temperatures { summarize(readSensors()) }

    /// Picks the CPU and SSD values out of raw sensor readings. Each sensor name appears
    /// several times on Apple silicon, so the CPU value is the hottest of all "tdie" sensors.
    static func summarize(_ readings: [(name: String, value: Double)]) -> Temperatures {
        let valid = readings.filter { validRange.contains($0.value) }
        var dies = valid.filter { $0.name.lowercased().contains("tdie") }.map(\.value)
        if dies.isEmpty {
            // Other hardware: fall back to any sensor whose name suggests the CPU or SoC.
            dies = valid.filter { r in
                let n = r.name.lowercased()
                return ["cpu", "soc", "pacc", "eacc"].contains { n.contains($0) }
            }.map(\.value)
        }
        let ssd = valid.filter { $0.name.lowercased().contains("nand") }.map(\.value).max()
        return Temperatures(
            cpuMax: dies.max(),
            cpuAverage: dies.isEmpty ? nil : dies.reduce(0, +) / Double(dies.count),
            ssd: ssd)
    }
}

// MARK: - System info

enum MemoryPressure: Equatable {
    case normal, warning, critical, unknown

    var label: String {
        switch self {
        case .normal: "normal"
        case .warning: "warning"
        case .critical: "critical"
        case .unknown: "unknown"
        }
    }
}

extension ProcessInfo.ThermalState {
    var label: String {
        switch self {
        case .nominal: "Nominal"
        case .fair: "Fair"
        case .serious: "Serious"
        case .critical: "Critical"
        @unknown default: "Unknown"
        }
    }
}

struct SystemInfo: Equatable {
    var load1 = 0.0, load5 = 0.0, load15 = 0.0
    var thermalState = ProcessInfo.ThermalState.nominal
    var totalMemory: UInt64 = 0
    var usedMemory: UInt64 = 0
    var memoryPressure = MemoryPressure.unknown
    /// Overall CPU usage in percent, or nil on the first sample (it needs two samples).
    var cpuUsage: Double?
}

/// Samples cheap system values. One instance keeps the previous CPU ticks, so call it
/// from one queue at a time.
final class SystemInfoSampler {
    private var previousTicks: (used: UInt64, total: UInt64)?

    func sample() -> SystemInfo {
        var info = SystemInfo()
        var load = [Double](repeating: 0, count: 3)
        if getloadavg(&load, 3) == 3 { (info.load1, info.load5, info.load15) = (load[0], load[1], load[2]) }
        info.thermalState = ProcessInfo.processInfo.thermalState
        info.totalMemory = ProcessInfo.processInfo.physicalMemory
        info.usedMemory = Self.usedMemory()
        info.memoryPressure = Self.memoryPressure()
        info.cpuUsage = cpuUsage()
        return info
    }

    /// Memory that Activity Monitor counts as used: app memory, wired, and compressed.
    private static func usedMemory() -> UInt64 {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        var pageSize: vm_size_t = 0
        guard result == KERN_SUCCESS, host_page_size(mach_host_self(), &pageSize) == KERN_SUCCESS else { return 0 }
        let appPages = UInt64(stats.internal_page_count) &- UInt64(stats.purgeable_count)
        let pages = appPages &+ UInt64(stats.wire_count) &+ UInt64(stats.compressor_page_count)
        return pages * UInt64(pageSize)
    }

    private static func memoryPressure() -> MemoryPressure {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else { return .unknown }
        switch level {
        case 1: return .normal
        case 2: return .warning
        case 4: return .critical
        default: return .unknown
        }
    }

    private func cpuUsage() -> Double? {
        var load = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &load) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let t = load.cpu_ticks  // user, system, idle, nice
        let used = UInt64(t.0) + UInt64(t.1) + UInt64(t.3)
        let total = used + UInt64(t.2)
        defer { previousTicks = (used, total) }
        guard let previous = previousTicks, total > previous.total else { return nil }
        return Double(used - previous.used) / Double(total - previous.total) * 100
    }
}

// MARK: - Process sampler

struct CPUHog: Identifiable, Equatable {
    let pid: Int32
    let uid: UInt32
    let cpuPercent: Double
    let rssBytes: UInt64
    let uptimeSeconds: Int
    let path: String
    let name: String
    /// The enclosing `.app` bundle name, such as "OrbStack" for "OrbStack Helper".
    let appName: String?
    let ownedByCurrentUser: Bool
    /// Stopping these can hang or log out the Mac, so the app offers no kill action.
    let isCritical: Bool

    var id: Int32 { pid }

    var uptime: String {
        let d = uptimeSeconds / 86400, h = uptimeSeconds % 86400 / 3600, m = uptimeSeconds % 3600 / 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        return m > 0 ? "\(m)m" : "\(uptimeSeconds)s"
    }

    /// The short user name, else the numeric user ID.
    var userName: String {
        if let entry = getpwuid(uid_t(uid)) { return String(cString: entry.pointee.pw_name) }
        return String(uid)
    }

    /// "Name" or "Name (App)", as the right-click menu shows it.
    var label: String { appName.map { "\(name) (\($0))" } ?? name }
}

enum ProcessSampler {
    static let criticalNames: Set<String> = ["kernel_task", "launchd", "WindowServer", "loginwindow"]

    /// Top CPU processes system-wide. `ps` reports CPU for root-owned processes without
    /// root, which libproc's per-process rusage cannot.
    static func sample(limit: Int = 15) -> [CPUHog] {
        let out = Scanner.run("/bin/ps", ["-Ao", "pid=,uid=,pcpu=,rss=,etime=,comm=", "-r"], timeout: 3)
        return parse(out, currentUID: getuid(), ownPID: getpid(), limit: limit)
    }

    /// Parses `ps` output with the columns pid, uid, pcpu, rss (KiB), etime, and comm. The
    /// command comes last because its path can contain spaces. Malformed lines are skipped.
    static func parse(_ output: String, currentUID: UInt32, ownPID: Int32, limit: Int = 15, minCPU: Double = 0.5) -> [CPUHog] {
        var hogs: [CPUHog] = []
        for line in output.split(separator: "\n") {
            var rest = Substring(line)
            var fields: [Substring] = []
            for _ in 0..<5 {
                rest = rest.drop { $0 == " " }
                guard let end = rest.firstIndex(of: " ") else { break }
                fields.append(rest[..<end])
                rest = rest[end...]
            }
            let path = rest.trimmingCharacters(in: .whitespaces)
            guard fields.count == 5, !path.isEmpty,
                  let pid = Int32(fields[0]), let uid = UInt32(fields[1]),
                  let cpu = Double(fields[2]), let rss = UInt64(fields[3]), cpu >= minCPU,
                  path != "/bin/ps"
            else { continue }
            let name = (path as NSString).lastPathComponent
            var appName: String?
            if let range = path.range(of: ".app/") {
                let app = (String(path[..<range.lowerBound]) as NSString).lastPathComponent
                if !app.isEmpty, app != name { appName = app }
            }
            hogs.append(CPUHog(
                pid: pid, uid: uid, cpuPercent: cpu, rssBytes: rss * 1024,
                uptimeSeconds: Scanner.parseElapsed(String(fields[4])),
                path: path, name: name, appName: appName,
                ownedByCurrentUser: uid == currentUID,
                isCritical: pid <= 1 || pid == ownPID || criticalNames.contains(name)))
        }
        return Array(hogs.sorted { $0.cpuPercent > $1.cpuPercent }.prefix(limit))
    }
}

// MARK: - Store

/// The window's two views.
enum MainView: String {
    case ports, system
}

final class SystemStore: ObservableObject {
    @Published var temperatures = Temperatures()
    @Published var info = SystemInfo()
    @Published var hogs: [CPUHog] = []
    /// Processes that couldn't be stopped, shown in an alert.
    @Published var killFailures: [String] = []
    @Published var showTemperature = UserDefaults.standard.object(forKey: "showTemperature") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showTemperature, forKey: "showTemperature") }
    }
    @Published var selectedView = MainView(rawValue: UserDefaults.standard.string(forKey: "mainView") ?? "") ?? .ports {
        didSet {
            // Save only a real change, so launching the app never writes the key.
            guard selectedView != oldValue else { return }
            UserDefaults.standard.set(selectedView.rawValue, forKey: "mainView")
            if selectedView == .system { refreshHogs() }
        }
    }

    /// Set by the app delegate. The `ps` sample runs only while this returns true and the
    /// System view is selected, so a hidden window costs nothing.
    var isWindowVisible: () -> Bool = { false }

    private let sampler = SystemInfoSampler()
    private var timer: Timer?
    private var sampling = false
    private var samplingHogs = false
    private var lastHogSample: Date?

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.tick() }
    }

    private func tick() {
        refresh()
        if selectedView == .system && isWindowVisible() { refreshHogs() }
    }

    /// Samples temperature and cheap system values on a background queue.
    func refresh() {
        // Skip if the previous sample is still running, so a slow call can't pile up.
        guard !sampling else { return }
        sampling = true
        DispatchQueue.global(qos: .utility).async {
            let temperatures = TemperatureReader.read()
            let info = self.sampler.sample()
            DispatchQueue.main.async {
                self.sampling = false
                if temperatures != self.temperatures { self.temperatures = temperatures }
                if info != self.info { self.info = info }
            }
        }
    }

    func refreshHogs() {
        guard !samplingHogs else { return }
        samplingHogs = true
        DispatchQueue.global(qos: .utility).async {
            let result = ProcessSampler.sample()
            DispatchQueue.main.async {
                self.samplingHogs = false
                self.lastHogSample = Date()
                if result != self.hogs { self.hogs = result }
            }
        }
    }

    /// The hog list for the right-click menu. Reuses a sample that is under `maxAge` seconds
    /// old, else samples on the calling thread (`ps` takes tens of milliseconds).
    func hogsForMenu(maxAge: TimeInterval = 10) -> [CPUHog] {
        if samplingHogs { return hogs }
        if let last = lastHogSample, Date().timeIntervalSince(last) < maxAge { return hogs }
        hogs = ProcessSampler.sample()
        lastHogSample = Date()
        return hogs
    }

    /// Stops a process on a background queue, reports failure, and refreshes the list.
    func kill(_ hog: CPUHog, force: Bool) {
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = Scanner.kill(hog.pid, force: force)
            DispatchQueue.main.async {
                if ok {
                    self.hogs.removeAll { $0.pid == hog.pid }
                } else {
                    self.killFailures = ["\(hog.name) (PID \(hog.pid))"]
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { self.refreshHogs() }
            }
        }
    }
}
