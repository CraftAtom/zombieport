import AppKit
import Combine
import ServiceManagement
import SwiftUI

@main
enum Main {
    static func main() {
        // `Zombieport --selftest` checks the platform parsers and exits non-zero on failure.
        if CommandLine.arguments.contains("--selftest") {
            let portCases: [(String, [Int])] = [
                ("0.0.0.0:5432->5432/tcp, [::]:5432->5432/tcp, 8080/tcp", [5432]),
                ("127.0.0.1:8080->80/tcp", [8080]),
                ("", []),
            ]
            for (input, want) in portCases where Containers.publishedPorts(input) != want {
                print("FAIL ports: \(input)"); exit(1)
            }
            let uptimeCases: [(String, Int)] = [
                ("Up 3 hours", 10800), ("Up 2 days", 172800),
                ("Up About an hour", 3600), ("Exited (0) 5 minutes ago", 0),
            ]
            for (input, want) in uptimeCases where Containers.parseUptime(input) != want {
                print("FAIL uptime: \(input)"); exit(1)
            }
            let elapsedCases: [(String, Int)] = [("2-03:04:05", 183845), ("04:05", 245), ("05", 5)]
            for (input, want) in elapsedCases where Scanner.parseElapsed(input) != want {
                print("FAIL elapsed: \(input)"); exit(1)
            }
            let psOutput = """
                  101     0  96.5  204800 03:04:05 /Applications/OrbStack.app/Contents/Frameworks/OrbStack Helper.app/Contents/MacOS/OrbStack Helper
                  202   501  12.0   10240 2-03:04:05 /Users/me/My Tools/bin/node
                    1     0   1.0    1000 05:00 /sbin/launchd
                  303   501   0.1    1000 00:10 /usr/bin/idle
                  404   501   3.0   2048 /bin/ps
                  not a ps line
                  505   501   2.0   2048 00:05
                """
            let hogs = ProcessSampler.parse(psOutput, currentUID: 501, ownPID: 999)
            guard hogs.map(\.pid) == [101, 202, 1] else { print("FAIL ps parse order/skips: \(hogs.map(\.pid))"); exit(1) }
            guard hogs[0].name == "OrbStack Helper", hogs[0].appName == "OrbStack", !hogs[0].ownedByCurrentUser,
                  hogs[0].rssBytes == 204800 * 1024, hogs[0].uptimeSeconds == 11045, !hogs[0].isCritical
            else { print("FAIL ps parse app helper"); exit(1) }
            guard hogs[1].path == "/Users/me/My Tools/bin/node", hogs[1].name == "node", hogs[1].appName == nil,
                  hogs[1].ownedByCurrentUser, hogs[1].uptimeSeconds == 183845
            else { print("FAIL ps parse path with spaces"); exit(1) }
            guard hogs[2].isCritical, !hogs[2].ownedByCurrentUser else { print("FAIL ps parse critical"); exit(1) }
            guard ProcessSampler.parse(psOutput, currentUID: 501, ownPID: 202).first(where: { $0.pid == 202 })?.isCritical == true
            else { print("FAIL ps parse own pid critical"); exit(1) }

            let sensors: [(name: String, value: Double)] = [
                ("PMU tdie1", 65), ("PMU tdie2", 70), ("PMU tdie3", -9200), ("PMU tdev1", 40), ("NAND CH0 temp", 38),
            ]
            guard TemperatureReader.summarize(sensors) == Temperatures(cpuMax: 70, cpuAverage: 67.5, ssd: 38)
            else { print("FAIL temperature summary"); exit(1) }
            guard TemperatureReader.summarize([("SOC MTR Temp", 50), ("gas gauge", 31)]).cpuMax == 50,
                  TemperatureReader.summarize([("gas gauge", 31), ("PMU tdie1", 200)]) == Temperatures()
            else { print("FAIL temperature fallback"); exit(1) }

            let titleCases: [(Int, Double?, Bool, Bool, String)] = [
                (3, 68.4, true, true, " 3 · 68°"),
                (0, 68.4, true, true, " 68°"),
                (3, 68.4, false, true, " 3"),
                (0, 68.4, false, true, ""),
                (0, 68.6, false, false, " 69°"),
                (3, nil, true, true, " 3"),
                (0, nil, true, false, ""),
            ]
            for (count, temp, show, nominal, want) in titleCases
            where AppDelegate.trayTitle(count: count, temperature: temp, showTemperature: show, thermalNominal: nominal) != want {
                print("FAIL tray title: \(count) \(String(describing: temp)) \(show) \(nominal)"); exit(1)
            }
            print("selftest ok")
            return
        }
        // `Zombieport --system` prints temperatures, system info, and top CPU processes.
        if CommandLine.arguments.contains("--system") {
            let t = TemperatureReader.read()
            func deg(_ v: Double?) -> String { v.map { String(format: "%.1f C", $0) } ?? "unavailable" }
            print("CPU temperature: \(deg(t.cpuMax)) (average \(deg(t.cpuAverage)))")
            print("SSD temperature: \(deg(t.ssd))")
            // CPU usage needs two samples.
            let sampler = SystemInfoSampler()
            _ = sampler.sample()
            Thread.sleep(forTimeInterval: 0.5)
            let i = sampler.sample()
            print("Thermal state: \(i.thermalState.label)")
            print("CPU usage: \(i.cpuUsage.map { String(format: "%.1f%%", $0) } ?? "unavailable")")
            print(String(format: "Load: %.2f %.2f %.2f", i.load1, i.load5, i.load15))
            let gib = { (b: UInt64) in String(format: "%.1f GB", Double(b) / 1_073_741_824) }
            print("Memory: \(gib(i.usedMemory)) of \(gib(i.totalMemory)), pressure \(i.memoryPressure.label)")
            print("PID\tCPU%\tMemory\tUser\tUptime\tName")
            for h in ProcessSampler.sample() {
                print("\(h.pid)\t\(String(format: "%.1f", h.cpuPercent))\t\(gib(h.rssBytes))\t\(h.userName)\t\(h.uptime)\t\(h.label)")
            }
            return
        }
        // `Zombieport --list [--all]` prints what the window would show and exits.
        if CommandLine.arguments.contains("--list") {
            for p in Scanner.scan(showAll: CommandLine.arguments.contains("--all")) {
                let pid = p.kind == .container ? "-" : String(p.pid)
                let state = p.kind == .container ? "container"
                    : p.appName != nil ? "app"
                    : p.isZombie ? "zombie"
                    : p.isStale(after: BadgeMode.staleDay.staleAfter) ? "stale" : "process"
                print("\(pid)\t\(p.portsLabel)\t\(p.projectName)\t\(p.repoName ?? "-")\t\(p.script)\t\(p.displayPath)\t\(state)")
            }
            return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

/// Registers the app as a login item through the modern Service Management API.
/// Fails cleanly on unsigned dev builds, where the toggle shows an alert instead.
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    @discardableResult
    static func set(_ enabled: Bool) -> Bool {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            return true
        } catch {
            return false
        }
    }
}

/// What the menu bar number counts.
enum BadgeMode: String, CaseIterable {
    case staleDay, staleThreeDays, zombies, all

    var title: String {
        switch self {
        case .staleDay: "Zombies + Older Than 24 Hours"
        case .staleThreeDays: "Zombies + Older Than 3 Days"
        case .zombies: "Zombies Only"
        case .all: "All Servers"
        }
    }

    /// Uptime after which a dev server counts as stale, or nil when age doesn't matter.
    var staleAfter: Int? {
        switch self {
        case .staleDay: 86400
        case .staleThreeDays: 3 * 86400
        case .zombies, .all: nil
        }
    }

    func counts(_ p: DevProcess) -> Bool {
        self == .all || p.isZombie || p.isStale(after: staleAfter)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = ProcessStore()
    private let system = SystemStore()
    private var statusItem: NSStatusItem!
    private var window: NSWindow?
    private var cancellable: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            // Monospaced digits keep the title width steady while the temperature changes.
            button.font = .monospacedDigitSystemFont(ofSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .regular)
        }
        system.isWindowVisible = { [weak self] in self?.window?.isVisible == true }
        let count = store.$processes.combineLatest(store.$badgeMode).map { processes, mode in
            processes.filter(mode.counts).count
        }
        cancellable = Publishers.CombineLatest4(count, system.$temperatures, system.$showTemperature, system.$info)
            .sink { [weak self] count, temperatures, show, info in
                self?.updateStatusItem(
                    count: count, temperature: temperatures.cpuMax, showTemperature: show,
                    thermalNominal: info.thermalState == .nominal)
            }
        if CommandLine.arguments.contains("--show") { showWindow() }
    }

    /// Template version of the logo: a port outline with crossed-out eyes.
    private static let menuBarIcon: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            NSColor.black.set()
            let body = NSBezierPath(roundedRect: NSRect(x: 1.75, y: 2.75, width: 14.5, height: 10.5), xRadius: 2.5, yRadius: 2.5)
            body.lineWidth = 1.5
            body.stroke()
            NSBezierPath(roundedRect: NSRect(x: 6, y: 13, width: 6, height: 3), xRadius: 1, yRadius: 1).fill()
            let eyes = NSBezierPath()
            eyes.lineWidth = 1.4
            eyes.lineCapStyle = .round
            for cx in [6.25, 11.75] {
                eyes.move(to: NSPoint(x: cx - 1.5, y: 5.5)); eyes.line(to: NSPoint(x: cx + 1.5, y: 8.5))
                eyes.move(to: NSPoint(x: cx - 1.5, y: 8.5)); eyes.line(to: NSPoint(x: cx + 1.5, y: 5.5))
            }
            eyes.stroke()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Zombieport"
        return image
    }()

    /// Launching the app again (Spotlight, Raycast, Finder) opens the window,
    /// which helps when the menu bar icon is hidden behind the notch.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return false
    }

    private func updateStatusItem(count: Int, temperature: Double?, showTemperature: Bool, thermalNominal: Bool) {
        guard let button = statusItem.button else { return }
        button.image = Self.menuBarIcon
        button.title = Self.trayTitle(
            count: count, temperature: temperature, showTemperature: showTemperature, thermalNominal: thermalNominal)
    }

    /// The text next to the icon. The temperature shows when you turn it on, and also when
    /// you turn it off but the Mac is throttling, because then it is worth knowing.
    /// Without a reading it falls back to the count alone.
    static func trayTitle(count: Int, temperature: Double?, showTemperature: Bool, thermalNominal: Bool) -> String {
        guard let temperature, showTemperature || !thermalNominal else {
            return count == 0 ? "" : " \(count)"
        }
        let degrees = "\(Int(temperature.rounded()))°"
        return count == 0 ? " \(degrees)" : " \(count) · \(degrees)"
    }

    @objc private func statusItemClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            addSystemSummary(to: menu)
            menu.addItem(withTitle: "Open Zombieport", action: #selector(showWindow), keyEquivalent: "").target = self
            menu.addItem(.separator())
            let badge = NSMenu()
            for mode in BadgeMode.allCases {
                let item = NSMenuItem(title: mode.title, action: #selector(setBadgeMode), keyEquivalent: "")
                item.target = self
                item.representedObject = mode.rawValue
                item.state = store.badgeMode == mode ? .on : .off
                badge.addItem(item)
            }
            let badgeItem = NSMenuItem(title: "Badge Counts", action: nil, keyEquivalent: "")
            badgeItem.submenu = badge
            menu.addItem(badgeItem)
            menu.addItem(.separator())
            let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLoginItem), keyEquivalent: "")
            login.target = self
            login.state = LoginItem.isEnabled ? .on : .off
            menu.addItem(login)
            let temperature = NSMenuItem(title: "Show Temperature", action: #selector(toggleShowTemperature), keyEquivalent: "")
            temperature.target = self
            temperature.state = system.showTemperature ? .on : .off
            menu.addItem(temperature)
            menu.addItem(.separator())
            menu.addItem(withTitle: "About Zombieport", action: #selector(showAbout), keyEquivalent: "").target = self
            menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil  // Restore left-click behavior.
            return
        }
        if let window, window.isVisible, window.isKeyWindow {
            window.orderOut(nil)
        } else {
            showWindow()
        }
    }

    /// A read-only summary at the top of the menu: temperature, load, memory pressure, and
    /// the top three CPU processes. Clicking a row opens the System view. The menu has no
    /// kill action, because a mis-click in a menu is too easy.
    private func addSystemSummary(to menu: NSMenu) {
        let hogs = system.hogsForMenu()
        let info = system.info
        let temperature = system.temperatures.cpuMax.map { "CPU \(Int($0.rounded())) °C" } ?? "Temperature unavailable"
        var rows = ["\(temperature) · Load \(String(format: "%.1f", info.load1)) · Memory pressure \(info.memoryPressure.label)"]
        rows += hogs.prefix(3).map { "\($0.label) — \(Int($0.cpuPercent.rounded()))%" }
        for row in rows {
            let item = NSMenuItem(title: row, action: #selector(showSystemView), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(.separator())
    }

    @objc private func showSystemView() {
        system.selectedView = .system
        showWindow()
    }

    @objc private func toggleShowTemperature() {
        system.showTemperature.toggle()
    }

    /// The standard About panel, with a short description and a link to CraftAtom.
    @objc private func showAbout() {
        let centered = NSMutableParagraphStyle()
        centered.alignment = .center
        let base: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: centered,
        ]
        let credits = NSMutableAttributedString(
            string: "Finds the dev servers that you forgot to stop, and stops them.\n\nMade by ",
            attributes: base)
        var link = base
        link[.link] = URL(string: "https://craftatom.com")!
        credits.append(NSAttributedString(string: "CraftAtom", attributes: link))
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    @objc private func setBadgeMode(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let mode = BadgeMode(rawValue: raw) {
            store.badgeMode = mode
        }
    }

    @objc private func toggleLoginItem() {
        let enable = !LoginItem.isEnabled
        guard !LoginItem.set(enable) else { return }
        let alert = NSAlert()
        alert.messageText = "Couldn't \(enable ? "enable" : "disable") Launch at Login"
        alert.informativeText = "Move Zombieport to /Applications and try again."
        alert.runModal()
    }

    @objc private func showWindow() {
        if window == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 900, height: 460),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered, defer: false)
            w.title = "Zombieport"
            w.isReleasedWhenClosed = false
            w.toolbarStyle = .unified
            let host = NSHostingController(rootView: RootView(store: store, system: system))
            host.sceneBridgingOptions = [.toolbars, .title]
            w.contentViewController = host
            w.setFrameAutosaveName("ZombieportMain")
            if !w.setFrameUsingName("ZombieportMain") { w.center() }
            window = w
        }
        store.refresh()
        system.refresh()
        if system.selectedView == .system { system.refreshHogs() }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

final class ProcessStore: ObservableObject {
    @Published var processes: [DevProcess] = []
    @Published var showAll = UserDefaults.standard.bool(forKey: "showAll") {
        didSet {
            UserDefaults.standard.set(showAll, forKey: "showAll")
            refresh()
        }
    }
    @Published var badgeMode = BadgeMode(rawValue: UserDefaults.standard.string(forKey: "badgeMode") ?? "") ?? .staleDay {
        didSet { UserDefaults.standard.set(badgeMode.rawValue, forKey: "badgeMode") }
    }
    /// Rows that couldn't be stopped, shown in an alert.
    @Published var killFailures: [String] = []
    private var timer: Timer?
    private var scanning = false

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func refresh() {
        // Skip if the previous scan is still running, so a slow docker/lsof call can't
        // pile up one stuck process every five seconds.
        guard !scanning else { return }
        scanning = true
        let showAll = showAll
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Scanner.scan(showAll: showAll)
            DispatchQueue.main.async {
                self.scanning = false
                if result != self.processes { self.processes = result }
            }
        }
    }

    var zombies: [DevProcess] { processes.filter(\.isZombie) }
    /// Old dev servers that aren't already zombies, so the two select buttons don't overlap.
    var stale: [DevProcess] { processes.filter { !$0.isZombie && $0.isStale(after: badgeMode.staleAfter) } }

    /// Stops processes and containers on a background queue, then removes what succeeded
    /// and leaves the rest in place with an alert.
    func kill(_ ids: Set<String>, force: Bool = false) {
        let targets = processes.filter { ids.contains($0.id) }
        guard !targets.isEmpty else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            var failed = Set<String>()
            for target in targets {
                let ok: Bool
                switch target.kind {
                case .container: ok = Scanner.stopContainer(target.container ?? "", force: force)
                case .process: ok = Scanner.kill(target.pid, force: force)
                }
                if !ok { failed.insert(target.id) }
            }
            DispatchQueue.main.async {
                self.killFailures = targets
                    .filter { failed.contains($0.id) }
                    .map { "\($0.projectName) (\($0.kind == .container ? "container" : "PID \($0.pid)"))" }
                self.processes.removeAll { ids.contains($0.id) && !failed.contains($0.id) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { self.refresh() }
            }
        }
    }
}

/// Hosts the toolbar's Ports and System picker and shows the selected view.
struct RootView: View {
    @ObservedObject var store: ProcessStore
    @ObservedObject var system: SystemStore

    var body: some View {
        Group {
            switch system.selectedView {
            case .ports: ContentView(store: store)
            case .system: SystemView(system: system)
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("View", selection: $system.selectedView) {
                    Text("Ports").tag(MainView.ports)
                    Text("System").tag(MainView.system)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .help("Switch between listening ports and system load")
            }
        }
    }
}

struct ContentView: View {
    @ObservedObject var store: ProcessStore
    @State private var selection = Set<String>()
    @State private var sortOrder = [KeyPathComparator(\DevProcess.firstPort)]
    @State private var search = ""
    @State private var pendingKill: PendingKill?

    /// A kill that waits for confirmation because it includes processes that apps started.
    struct PendingKill {
        let ids: Set<String>
        let force: Bool
        let apps: [String]
    }

    private var rows: [DevProcess] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        let filtered = q.isEmpty ? store.processes : store.processes.filter { p in
            [p.projectName, p.repoName ?? "", p.script, p.displayPath, p.portsLabel, String(p.pid)]
                .contains { $0.lowercased().contains(q) }
        }
        return filtered.sorted(using: sortOrder)
    }

    var body: some View {
        Group {
            if rows.isEmpty {
                emptyState
            } else {
                table
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
        .searchable(text: $search, placement: .toolbar, prompt: "Name, port, or path")
        .navigationTitle("Zombieport")
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Toggle(isOn: $store.showAll) {
                    Label("All Listeners", systemImage: "network")
                }
                .labelStyle(.titleAndIcon)
                .help("Show every process listening on a TCP port, not only dev runtimes")
                Button { store.refresh() } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Refresh")
            }
        }
        .frame(minWidth: 700, minHeight: 260)
        // Keep only visible rows selected, so Kill never stops a hidden or exited process.
        .onChange(of: store.processes) { pruneSelection() }
        .onChange(of: search) { pruneSelection() }
        .alert(
            "Couldn't stop some processes",
            isPresented: Binding(get: { !store.killFailures.isEmpty }, set: { if !$0 { store.killFailures = [] } })
        ) {
            Button("OK") {}
        } message: {
            Text(store.killFailures.joined(separator: "\n") + "\n\nThey may belong to another user, or their runtime may be unavailable.")
        }
        .alert(
            "Stop processes that apps depend on?",
            isPresented: Binding(get: { pendingKill != nil }, set: { if !$0 { pendingKill = nil } }),
            presenting: pendingKill
        ) { k in
            Button(k.force ? "Force Kill" : "Kill", role: .destructive) { store.kill(k.ids, force: k.force) }
            Button("Cancel", role: .cancel) {}
        } message: { k in
            Text("\(k.apps.formatted(.list(type: .and))) started some of the selected processes. Stopping them can make \(k.apps.count == 1 ? "that app" : "those apps") quit or stop working.")
        }
    }

    /// Stops the rows, but asks first when any of them belongs to an app, because an app
    /// such as Raycast quits when its helper process stops.
    private func requestKill(_ ids: Set<String>, force: Bool = false) {
        let apps = Set(store.processes.filter { ids.contains($0.id) }.compactMap(\.appName)).sorted()
        if apps.isEmpty {
            store.kill(ids, force: force)
        } else {
            pendingKill = PendingKill(ids: ids, force: force, apps: apps)
        }
    }

    private var subtitle: String {
        let total = store.processes.count == 1 ? "1 server" : "\(store.processes.count) servers"
        let flagged = store.zombies.count + store.stale.count
        return flagged == 0 ? total : "\(total) · \(flagged) need\(flagged == 1 ? "s" : "") attention"
    }

    private func pruneSelection() {
        selection.formIntersection(rows.map(\.id))
    }

    private var table: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Port", value: \.firstPort) { p in
                HStack(spacing: 4) {
                    ForEach(p.ports.prefix(3), id: \.self) { PortChip(port: $0) }
                    if p.ports.count > 3 {
                        Text(verbatim: "+\(p.ports.count - 3)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .help(p.portsLabel)
                    }
                }
            }
            .width(min: 70, ideal: 100)
            TableColumn("Name", value: \.projectName) { p in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(p.projectName).fontWeight(.semibold)
                        if let app = p.appName {
                            Text("app")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(.blue.opacity(0.2)))
                                .foregroundStyle(.blue)
                                .help("\(app) started this process, so stopping it can make \(app) quit")
                        } else if p.isZombie {
                            Text("zombie")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(.orange.opacity(0.2)))
                                .foregroundStyle(.orange)
                                .help("Its parent process is gone, so nothing will ever stop it")
                        } else if p.isStale(after: store.badgeMode.staleAfter) {
                            Text("stale")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(.secondary.opacity(0.2)))
                                .foregroundStyle(.secondary)
                                .help("Running for \(p.uptime), so you may have forgotten it")
                        }
                    }
                    Text([p.repoName, p.script].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .lineLimit(1)
                .padding(.vertical, 3)
                .help(p.args)
            }
            .width(min: 160, ideal: 260)
            TableColumn("Location", value: \.displayPath) { p in
                Text(p.displayPath)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(p.cwd ?? "")
            }
            .width(min: 160, ideal: 280)
            TableColumn("PID", value: \.pid) { p in
                Text(verbatim: p.kind == .container ? "—" : String(p.pid))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(min: 50, ideal: 60)
            TableColumn("Uptime", value: \.uptimeSeconds) { p in
                Text(p.uptime).monospacedDigit().foregroundStyle(.secondary)
            }
            .width(min: 50, ideal: 70)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            contextMenu(for: ids)
        } primaryAction: { ids in
            // Double-click opens the first port in the browser.
            openInBrowser(ids)
        }
        // Scoped to the table so Delete in the search field only edits text.
        .onDeleteCommand { requestKill(selection) }
    }

    private var emptyState: some View {
        Group {
            if search.isEmpty {
                ContentUnavailableView(
                    "No Dev Servers Running",
                    systemImage: "checkmark.circle",
                    description: Text("Node, Bun, Deno, Python, and other dev servers appear here when they listen on a port."))
            } else {
                ContentUnavailableView.search(text: search)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var bottomBar: some View {
        HStack(spacing: 10) {
            Text(selection.isEmpty ? "Double-click a row to open it in the browser" : "\(selection.count) selected")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            if !store.zombies.isEmpty {
                Button("Select \(store.zombies.count) Zombie\(store.zombies.count == 1 ? "" : "s")") {
                    selection = Set(store.zombies.map(\.id))
                }
                .help("Select every server whose parent process is gone")
            }
            if !store.stale.isEmpty {
                Button("Select \(store.stale.count) Stale") {
                    selection = Set(store.stale.map(\.id))
                }
                .help("Select every dev server older than the badge's age limit")
            }
            if selection.isEmpty {
                Button("Select All") { selection = Set(rows.map(\.id)) }
                    .disabled(rows.isEmpty)
            } else {
                Button("Deselect") { selection.removeAll() }
            }
            Button(role: .destructive) {
                requestKill(selection)
            } label: {
                Label(selection.count > 1 ? "Kill \(selection.count)" : "Kill", systemImage: "xmark.octagon.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(selection.isEmpty)
            .help("Stop the selected processes (Delete)")
        }
        .controlSize(.large)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    @ViewBuilder
    private func contextMenu(for ids: Set<String>) -> some View {
        let selected = store.processes.filter { ids.contains($0.id) }
        if !selected.isEmpty {
            Button(ids.count == 1 ? "Kill" : "Kill \(ids.count) Processes") { requestKill(ids) }
            Button("Force Kill") { requestKill(ids, force: true) }
            Divider()
            // A single row with several ports gets a submenu so any port can be opened.
            if selected.count == 1, let ports = selected.first?.ports, ports.count > 1 {
                Menu("Open in Browser") {
                    ForEach(ports, id: \.self) { port in
                        Button(String("localhost:\(port)")) { PortChip.open(port) }
                    }
                }
                Menu("Open in Browser (HTTPS)") {
                    ForEach(ports, id: \.self) { port in
                        Button(String("localhost:\(port)")) { PortChip.open(port, https: true) }
                    }
                }
            } else {
                Button("Open in Browser") { openInBrowser(ids) }
                Button("Open in Browser (HTTPS)") { openInBrowser(ids, https: true) }
            }
            // Offer to stop the rest of the same project in one click.
            if let key = selected.first?.projectKey {
                let siblings = store.processes.filter { $0.projectKey == key && !ids.contains($0.id) }
                if !siblings.isEmpty {
                    Button("Stop \(siblings.count) more in \(selected.first?.repoName ?? key)") {
                        store.kill(Set(siblings.map(\.id)))
                    }
                }
            }
            if selected.count == 1, let p = selected.first {
                if let cwd = p.cwd {
                    Button("Reveal in Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: cwd) }
                    Button("Copy Path") { copy(cwd) }
                }
                Button("Copy Command") { copy(p.args) }
                if p.kind == .process { Button("Copy PID") { copy(String(p.pid)) } }
                if p.isZombie { Button("Kill Zombie") { store.kill([p.id]) } }
            }
        }
    }

    private func openInBrowser(_ ids: Set<String>, https: Bool = false) {
        for p in store.processes where ids.contains(p.id) {
            if let port = p.ports.first { PortChip.open(port, https: https) }
        }
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}

struct PortChip: View {
    let port: Int
    @State private var hovering = false

    static func open(_ port: Int, https: Bool = false) {
        if let url = URL(string: "\(https ? "https" : "http")://localhost:\(port)") { NSWorkspace.shared.open(url) }
    }

    var body: some View {
        Button { Self.open(port) } label: {
            Text(verbatim: String(port))
                .font(.system(.callout, design: .monospaced).weight(.semibold))
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.accentColor.opacity(hovering ? 0.28 : 0.14)))
                .foregroundStyle(Color.accentColor)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Open http://localhost:\(port)")
    }
}
