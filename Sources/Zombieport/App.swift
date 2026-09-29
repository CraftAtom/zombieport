import AppKit
import Combine
import SwiftUI

@main
enum Main {
    static func main() {
        // `Zombieport --list [--all]` prints what the window would show and exits.
        if CommandLine.arguments.contains("--list") {
            for p in Scanner.scan(showAll: CommandLine.arguments.contains("--all")) {
                print("\(p.pid)\t\(p.portsLabel)\t\(p.projectName)\t\(p.repoName ?? "-")\t\(p.script)\t\(p.displayPath)")
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

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = ProcessStore()
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
        }
        cancellable = store.$processes.sink { [weak self] in self?.updateStatusItem(count: $0.count) }
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

    private func updateStatusItem(count: Int) {
        guard let button = statusItem.button else { return }
        button.image = Self.menuBarIcon
        button.title = count == 0 ? "" : " \(count)"
    }

    @objc private func statusItemClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            menu.addItem(withTitle: "Open Zombieport", action: #selector(showWindow), keyEquivalent: "").target = self
            menu.addItem(.separator())
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

    @objc private func showWindow() {
        if window == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 900, height: 460),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered, defer: false)
            w.title = "Zombieport"
            w.isReleasedWhenClosed = false
            w.toolbarStyle = .unified
            let host = NSHostingController(rootView: ContentView(store: store))
            host.sceneBridgingOptions = [.toolbars, .title]
            w.contentViewController = host
            w.setFrameAutosaveName("ZombieportMain")
            if !w.setFrameUsingName("ZombieportMain") { w.center() }
            window = w
        }
        store.refresh()
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
    private var timer: Timer?

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func refresh() {
        let showAll = showAll
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Scanner.scan(showAll: showAll)
            DispatchQueue.main.async {
                if result != self.processes { self.processes = result }
            }
        }
    }

    /// Names of processes that couldn't be stopped, shown in an alert.
    @Published var killFailures: [String] = []

    func kill(_ pids: Set<Int32>, force: Bool = false) {
        let failed = pids.filter { !Scanner.kill($0, force: force) }
        killFailures = processes.filter { failed.contains($0.pid) }.map { "\($0.projectName) (PID \($0.pid))" }
        processes.removeAll { pids.contains($0.pid) && !failed.contains($0.pid) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { self.refresh() }
    }
}

struct ContentView: View {
    @ObservedObject var store: ProcessStore
    @State private var selection = Set<Int32>()
    @State private var sortOrder = [KeyPathComparator(\DevProcess.firstPort)]
    @State private var search = ""

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
        .navigationSubtitle(store.processes.count == 1 ? "1 server" : "\(store.processes.count) servers")
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
            Text(store.killFailures.joined(separator: "\n") + "\n\nThey may belong to another user or to the system.")
        }
    }

    private func pruneSelection() {
        selection.formIntersection(rows.map(\.pid))
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
                    Text(p.projectName).fontWeight(.semibold)
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
                Text(verbatim: String(p.pid)).monospacedDigit().foregroundStyle(.secondary)
            }
            .width(min: 50, ideal: 60)
            TableColumn("Uptime", value: \.uptimeSeconds) { p in
                Text(p.uptime).monospacedDigit().foregroundStyle(.secondary)
            }
            .width(min: 50, ideal: 70)
        }
        .contextMenu(forSelectionType: Int32.self) { pids in
            contextMenu(for: pids)
        } primaryAction: { pids in
            // Double-click opens the first port in the browser.
            openInBrowser(pids)
        }
        // Scoped to the table so Delete in the search field only edits text.
        .onDeleteCommand { store.kill(selection) }
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
            if selection.isEmpty {
                Button("Select All") { selection = Set(rows.map(\.pid)) }
                    .disabled(rows.isEmpty)
            } else {
                Button("Deselect") { selection.removeAll() }
            }
            Button(role: .destructive) {
                store.kill(selection)
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
    private func contextMenu(for pids: Set<Int32>) -> some View {
        let selected = store.processes.filter { pids.contains($0.pid) }
        if !selected.isEmpty {
            Button(pids.count == 1 ? "Kill" : "Kill \(pids.count) Processes") { store.kill(pids) }
            Button("Force Kill (SIGKILL)") { store.kill(pids, force: true) }
            Divider()
            Button("Open in Browser") { openInBrowser(pids) }
            if selected.count == 1, let p = selected.first {
                if let cwd = p.cwd {
                    Button("Reveal in Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: cwd) }
                    Button("Copy Path") { copy(cwd) }
                }
                Button("Copy Command") { copy(p.args) }
                Button("Copy PID") { copy(String(p.pid)) }
            }
        }
    }

    private func openInBrowser(_ pids: Set<Int32>) {
        for p in store.processes where pids.contains(p.pid) {
            if let port = p.ports.first { PortChip.open(port) }
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

    static func open(_ port: Int) {
        if let url = URL(string: "http://localhost:\(port)") { NSWorkspace.shared.open(url) }
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
