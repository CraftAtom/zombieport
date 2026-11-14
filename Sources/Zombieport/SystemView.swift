import AppKit
import SwiftUI

/// The System view: a header strip of temperature and load values, and a table of the
/// processes that use the most CPU.
struct SystemView: View {
    @ObservedObject var system: SystemStore
    @State private var sortOrder = [KeyPathComparator(\HogRow.hog.cpuPercent, order: .reverse)]
    @State private var search = ""
    @State private var selection = Set<Int>()
    @State private var pendingKill: PendingHogKill?

    /// A kill that waits for confirmation. Every kill from this view asks first, because
    /// the list includes processes that you did not start.
    struct PendingHogKill {
        let hog: CPUHog
        let force: Bool
    }

    /// A table row keyed by its position, not by PID. Busy processes come and go every few
    /// seconds, and a table whose row identities change inserts and removes rows inside its
    /// own update, which makes AppKit log a reentrant NSTableView delegate warning. With
    /// position keys, a refresh only updates the cells.
    struct HogRow: Identifiable {
        let id: Int
        let hog: CPUHog
    }

    private var rows: [HogRow] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        let filtered = q.isEmpty ? system.hogs : system.hogs.filter { h in
            [h.name, h.appName ?? "", h.path, h.userName, String(h.pid)].contains { $0.lowercased().contains(q) }
        }
        return filtered.map { HogRow(id: 0, hog: $0) }
            .sorted(using: sortOrder)
            .enumerated().map { HogRow(id: $0.offset, hog: $0.element.hog) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if rows.isEmpty {
                emptyState
            } else {
                table
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
        .searchable(text: $search, placement: .toolbar, prompt: "Name, app, or PID")
        .navigationTitle("Zombieport")
        .navigationSubtitle("System")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { system.refresh(); system.refreshHogs() } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Refresh")
            }
        }
        .frame(minWidth: 700, minHeight: 260)
        // Write only when something changed, because a state write inside a table update is a reentrant call.
        .onChange(of: system.hogs) {
            let pruned = selection.filter { $0 < system.hogs.count }
            if pruned != selection { selection = pruned }
        }
        .alert(
            "Couldn't stop the process",
            isPresented: Binding(get: { !system.killFailures.isEmpty }, set: { if !$0 { system.killFailures = [] } })
        ) {
            Button("OK") {}
        } message: {
            Text(system.killFailures.joined(separator: "\n") + "\n\nIt may belong to another user, or it may have already exited.")
        }
        .alert(
            pendingKill.map { "\($0.force ? "Force kill" : "Kill") \($0.hog.name) (PID \($0.hog.pid))?" } ?? "",
            isPresented: Binding(get: { pendingKill != nil }, set: { if !$0 { pendingKill = nil } }),
            presenting: pendingKill
        ) { k in
            Button(k.force ? "Force Kill" : "Kill", role: .destructive) { system.kill(k.hog, force: k.force) }
            Button("Cancel", role: .cancel) {}
        } message: { k in
            Text(k.force
                 ? "Zombieport sends SIGKILL, and the process cannot save its work."
                 : "Zombieport sends SIGTERM, then SIGKILL if the process still runs after two seconds.")
        }
    }

    // MARK: Header

    private var header: some View {
        let t = system.temperatures, i = system.info
        return HStack(alignment: .top, spacing: 28) {
            stat("CPU temperature", t.cpuMax.map(degrees) ?? "Unavailable",
                 secondary: t.cpuAverage.map { "average \(degrees($0))" })
            if let ssd = t.ssd { stat("SSD temperature", degrees(ssd)) }
            stat("Thermal state", i.thermalState.label)
            stat("CPU usage", i.cpuUsage.map { "\(Int($0.rounded()))%" } ?? "Unavailable")
            stat("Load (1, 5, 15 min)", String(format: "%.2f  %.2f  %.2f", i.load1, i.load5, i.load15))
            stat("Memory", i.totalMemory == 0 ? "Unavailable" : "\(bytes(i.usedMemory)) of \(bytes(i.totalMemory))",
                 secondary: "pressure \(i.memoryPressure.label)")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private func stat(_ title: String, _ value: String, secondary: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(verbatim: value).font(.title3.weight(.semibold)).monospacedDigit()
            if let secondary { Text(verbatim: secondary).font(.caption).foregroundStyle(.secondary) }
        }
        .lineLimit(1)
    }

    private func degrees(_ value: Double) -> String { "\(Int(value.rounded())) °C" }

    private func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .memory)
    }

    // MARK: Table

    private var table: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.hog.name) { row in
                let h = row.hog
                Text(h.name).fontWeight(.semibold).lineLimit(1).help(h.path)
            }
            .width(min: 140, ideal: 220)
            TableColumn("App") { row in
                let h = row.hog
                Text(h.appName ?? "").foregroundStyle(.secondary).lineLimit(1)
            }
            .width(min: 80, ideal: 120)
            TableColumn("PID", value: \.hog.pid) { row in
                let h = row.hog
                Text(verbatim: String(h.pid)).monospacedDigit().foregroundStyle(.secondary)
            }
            .width(min: 50, ideal: 60)
            TableColumn("CPU %", value: \.hog.cpuPercent) { row in
                let h = row.hog
                Text(verbatim: String(format: "%.1f", h.cpuPercent)).monospacedDigit()
            }
            .width(min: 50, ideal: 60)
            TableColumn("Memory", value: \.hog.rssBytes) { row in
                let h = row.hog
                Text(bytes(h.rssBytes)).monospacedDigit().foregroundStyle(.secondary)
            }
            .width(min: 60, ideal: 80)
            TableColumn("User") { row in
                let h = row.hog
                Text(verbatim: h.userName).foregroundStyle(.secondary).lineLimit(1)
            }
            .width(min: 60, ideal: 90)
            TableColumn("Uptime", value: \.hog.uptimeSeconds) { row in
                let h = row.hog
                Text(h.uptime).monospacedDigit().foregroundStyle(.secondary)
            }
            .width(min: 50, ideal: 70)
            TableColumn("") { row in
                let h = row.hog
                Menu { actions(for: h) } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
            }
            .width(30)
        }
        .transaction { $0.animation = nil }
        .contextMenu(forSelectionType: Int.self) { ids in
            if ids.count == 1, let id = ids.first, id < rows.count { actions(for: rows[id].hog) }
        }
    }

    /// Kill actions depend on who owns the process: your own processes can be stopped here,
    /// root-owned ones need `sudo` in Terminal, and critical ones get no action at all.
    @ViewBuilder
    private func actions(for h: CPUHog) -> some View {
        if !h.isCritical {
            if h.ownedByCurrentUser {
                Button("Kill") { pendingKill = PendingHogKill(hog: h, force: false) }
                Button("Force Kill") { pendingKill = PendingHogKill(hog: h, force: true) }
            } else {
                Button("Copy sudo kill command") { copy("sudo kill \(h.pid)") }
                Button("Copy sudo force-kill command") { copy("sudo kill -9 \(h.pid)") }
            }
            Divider()
        }
        Button("Copy PID") { copy(String(h.pid)) }
    }

    private var emptyState: some View {
        Group {
            if search.isEmpty {
                ContentUnavailableView(
                    "No Busy Processes",
                    systemImage: "checkmark.circle",
                    description: Text("Processes that use at least 0.5% of a CPU core appear here."))
            } else {
                ContentUnavailableView.search(text: search)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var bottomBar: some View {
        HStack {
            Text("Root-owned processes need Terminal: copy the sudo command and run it there.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}
