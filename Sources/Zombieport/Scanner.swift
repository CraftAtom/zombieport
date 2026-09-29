import Foundation

struct DevProcess: Identifiable, Equatable {
    enum Kind: Equatable { case process, container }

    var kind: Kind = .process
    let pid: Int32
    let ppid: Int32
    let command: String
    let args: String
    let cwd: String?
    let ports: [Int]
    let uptimeSeconds: Int
    let projectName: String
    let repoName: String?
    let script: String
    /// Container name, used to stop container rows.
    let container: String?

    var id: String { kind == .container ? "c:\(container ?? "")" : "p:\(pid)" }
    var firstPort: Int { ports.first ?? 0 }
    var portsLabel: String { ports.map(String.init).joined(separator: ", ") }

    /// The process was reparented to launchd, so the shell that started it is gone and
    /// nothing will ever stop it. That is the "zombie" this app exists to find.
    ///
    /// Only dev runtimes qualify: GUI apps, agents, and launchd services all have PPID 1
    /// by design, so flagging them would make "zombie" meaningless.
    var isZombie: Bool { kind == .process && ppid == 1 && Scanner.isDevRuntime(command) }

    var uptime: String {
        let d = uptimeSeconds / 86400, h = uptimeSeconds % 86400 / 3600, m = uptimeSeconds % 3600 / 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        return m > 0 ? "\(m)m" : "\(uptimeSeconds)s"
    }

    /// package.json "name" in the working directory, else the directory's basename.
    static func projectName(cwd: String?, command: String) -> String {
        guard let cwd else { return command }
        let pkg = URL(fileURLWithPath: cwd).appendingPathComponent("package.json")
        if let data = try? Data(contentsOf: pkg),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let name = json["name"] as? String, !name.isEmpty {
            return name
        }
        let base = (cwd as NSString).lastPathComponent
        return base.isEmpty || base == "/" ? command : base
    }

    /// Name of the nearest enclosing directory that contains `.git`.
    static func repoName(cwd: String?) -> String? {
        guard var dir = cwd else { return nil }
        let fm = FileManager.default
        while dir != "/" && !dir.isEmpty {
            if fm.fileExists(atPath: dir + "/.git") { return (dir as NSString).lastPathComponent }
            dir = (dir as NSString).deletingLastPathComponent
        }
        return nil
    }

    /// A short summary of what the process runs, such as "tsx src/server.ts" or
    /// "astro preview", derived from its command line.
    static func script(args: String, command: String) -> String {
        var tool: String?
        var rest: [String] = []
        for token in args.split(separator: " ").dropFirst().map(String.init) {
            // Resolve ".bin/../tsx/..." so the package name is the real one.
            let token = token.replacingOccurrences(of: "node_modules/.bin/../", with: "node_modules/")
            if let range = token.range(of: "node_modules/", options: .backwards) {
                // ".../node_modules/@scope/pkg/bin/x.js" -> "pkg"
                let parts = token[range.upperBound...].split(separator: "/")
                let pkg = parts.first?.hasPrefix("@") == true && parts.count > 1 ? parts[1] : parts.first
                if tool == nil, let pkg, pkg != ".bin" { tool = String(pkg) }
                continue
            }
            if token.hasPrefix("-") || token.hasPrefix("file:") || Int(token) != nil { continue }
            // Skip absolute paths and fragments of app bundle paths that contain spaces.
            if token.contains("/") && (token.hasPrefix("/") || token.contains(".app/") || !token.contains(".")) { continue }
            if command.split(separator: " ").contains(Substring(token)) { continue }
            if rest.count < 2 { rest.append(token.count > 40 ? String(token.prefix(40)) + "…" : token) }
        }
        return ([tool ?? command] + rest).joined(separator: " ")
    }

    var displayPath: String {
        guard let cwd else { return kind == .container ? "container" : "unknown location" }
        let home = NSHomeDirectory()
        return cwd == home || cwd.hasPrefix(home + "/") ? "~" + cwd.dropFirst(home.count) : cwd
    }

    /// The key that groups servers belonging to one project: its repo, else its folder.
    var projectKey: String? {
        guard kind == .process else { return nil }
        return repoName ?? cwd.map { ($0 as NSString).lastPathComponent }
    }
}

enum Containers {
    struct Info {
        let id: String
        let name: String
        let image: String
        let ports: [Int]
        let uptime: Int
    }

    /// Running containers with published ports, from the Docker CLI (which also serves
    /// OrbStack, Colima, and Docker Desktop). Returns `[]` when the CLI is missing, the
    /// daemon is down, or nothing is published, so the app degrades to plain process
    /// scanning with no error shown to the user.
    static func list() -> [Info] {
        // /usr/bin/env always exists; if docker doesn't, env exits non-zero with no output.
        let out = Scanner.run(
            "/usr/bin/env",
            ["docker", "ps", "--no-trunc", "--format", "{{.ID}}\t{{.Names}}\t{{.Image}}\t{{.Ports}}\t{{.Status}}"],
            timeout: 3)
        var result: [Info] = []
        for line in out.split(separator: "\n") {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard f.count == 5 else { continue }
            let ports = publishedPorts(f[3])
            guard !ports.isEmpty else { continue }
            result.append(Info(id: f[0], name: f[1], image: f[2], ports: ports, uptime: parseUptime(f[4])))
        }
        return result
    }

    /// Host ports from a docker ports string like
    /// "0.0.0.0:5432->5432/tcp, [::]:5432->5432/tcp, 8080/tcp".
    static func publishedPorts(_ s: String) -> [Int] {
        var ports = Set<Int>()
        for mapping in s.split(separator: ",") {
            let part = mapping.trimmingCharacters(in: .whitespaces)
            guard let arrow = part.range(of: "->") else { continue }   // "8080/tcp" is not published
            let host = part[..<arrow.lowerBound]                        // "0.0.0.0:5432" or "[::]:5432"
            guard let colon = host.lastIndex(of: ":") else { continue }
            if let port = Int(host[host.index(after: colon)...]) { ports.insert(port) }
        }
        return ports.sorted()
    }

    /// Best-effort seconds from a docker status string ("Up 3 hours", "Up 2 days").
    static func parseUptime(_ status: String) -> Int {
        let words = status.lowercased().split(separator: " ")
        guard let up = words.firstIndex(of: "up") else { return 0 }
        let rest = words.dropFirst(up + 1)
        func unit(_ word: Substring) -> Int {
            if word.hasPrefix("second") { return 1 }
            if word.hasPrefix("minute") { return 60 }
            if word.hasPrefix("hour") { return 3600 }
            if word.hasPrefix("day") { return 86400 }
            if word.hasPrefix("week") { return 604_800 }
            if word.hasPrefix("month") { return 2_592_000 }
            if word.hasPrefix("year") { return 31_536_000 }
            return 0
        }
        let count = rest.first.flatMap { Int($0) } ?? 1
        guard let word = rest.first(where: { unit($0) > 0 }) else { return 0 }
        return count * unit(word)
    }
}

enum Scanner {
    /// Command names treated as dev runtimes when "show all" is off.
    static let devRuntimes = [
        "node", "bun", "deno", "python", "ruby", "java", "php", "go", "dotnet",
        "uvicorn", "gunicorn", "rails", "puma", "beam.smp", "elixir", "cargo",
        "npm", "pnpm", "yarn", "npx", "next-server", "vite", "esbuild", "workerd",
        "wrangler", "tsx", "ts-node", "nodemon", "flask", "django", "hugo", "caddy",
    ]

    static func isDevRuntime(_ command: String) -> Bool {
        // "python3.12" -> "python", "next-server (v15.0.0)" -> "next-server"
        let word = command.lowercased().split(separator: " ").first.map(String.init) ?? ""
        let name = word.trimmingCharacters(in: CharacterSet(charactersIn: "0123456789."))
        return devRuntimes.contains(name)
    }

    static func scan(showAll: Bool) -> [DevProcess] {
        // Ports published by running containers, so their rows can replace the daemon
        // process rows (which are not dev runtimes and can't be killed to free a port).
        let containers = Containers.list()
        var containerByPort: [Int: Containers.Info] = [:]
        for c in containers { for port in c.ports { containerByPort[port] = c } }

        // pid -> (command, ports)
        var listeners: [Int32: (command: String, ports: Set<Int>)] = [:]
        var currentPid: Int32?
        for line in run("/usr/sbin/lsof", ["+c", "0", "-nP", "-iTCP", "-sTCP:LISTEN", "-F", "pcn"], timeout: 3)
            .split(separator: "\n") {
            let value = String(line.dropFirst())
            switch line.first {
            case "p":
                currentPid = Int32(value)
                if let pid = currentPid, listeners[pid] == nil { listeners[pid] = ("", []) }
            case "c":
                if let pid = currentPid { listeners[pid]?.command = value }
            case "n":
                if let pid = currentPid, let port = value.split(separator: ":").last.flatMap({ Int($0) }) {
                    listeners[pid]?.ports.insert(port)
                }
            default: break
            }
        }

        let pids = listeners
            .filter { showAll || isDevRuntime($0.value.command) }
            .map(\.key)

        var rows: [DevProcess] = []
        if !pids.isEmpty {
            let pidList = pids.map(String.init).joined(separator: ",")

            // Working directories.
            var cwds: [Int32: String] = [:]
            currentPid = nil
            for line in run("/usr/sbin/lsof", ["-a", "-d", "cwd", "-p", pidList, "-F", "pn"], timeout: 3).split(separator: "\n") {
                let value = String(line.dropFirst())
                if line.first == "p" { currentPid = Int32(value) }
                if line.first == "n", let pid = currentPid { cwds[pid] = value }
            }

            // Uptime, parent PID, and full command line.
            var info: [Int32: (uptime: String, ppid: Int32, args: String)] = [:]
            for line in run("/bin/ps", ["-o", "pid=,ppid=,etime=,args=", "-p", pidList], timeout: 3).split(separator: "\n") {
                let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
                guard parts.count == 4, let pid = Int32(parts[0]) else { continue }
                info[pid] = (String(parts[2]), Int32(parts[1]) ?? 0, String(parts[3]))
            }

            rows = pids.compactMap { pid in
                guard let l = listeners[pid] else { return nil }
                // Ports owned by a container belong to its row, not the daemon's.
                let own = l.ports.filter { containerByPort[$0] == nil }.sorted()
                if own.isEmpty { return nil }
                return DevProcess(
                    pid: pid,
                    ppid: info[pid]?.ppid ?? 0,
                    command: l.command,
                    args: info[pid]?.args ?? l.command,
                    cwd: cwds[pid],
                    ports: own,
                    uptimeSeconds: parseElapsed(info[pid]?.uptime ?? ""),
                    projectName: DevProcess.projectName(cwd: cwds[pid], command: l.command),
                    repoName: DevProcess.repoName(cwd: cwds[pid]),
                    script: DevProcess.script(args: info[pid]?.args ?? "", command: l.command),
                    container: nil
                )
            }
        }

        for c in containers {
            rows.append(DevProcess(
                kind: .container,
                pid: 0,
                ppid: 0,
                command: c.image,
                args: "docker stop \(c.name)",
                cwd: nil,
                ports: c.ports,
                uptimeSeconds: c.uptime,
                projectName: c.name,
                repoName: "container",
                script: c.image,
                container: c.name
            ))
        }

        return rows.sorted {
            ($0.ports.first ?? 0, $0.projectName) < ($1.ports.first ?? 0, $1.projectName)
        }
    }

    /// Parses ps etime, formatted as [[dd-]hh:]mm:ss.
    static func parseElapsed(_ s: String) -> Int {
        let dayParts = s.split(separator: "-")
        let days = dayParts.count == 2 ? Int(dayParts[0]) ?? 0 : 0
        let clock = (dayParts.last ?? "").split(separator: ":").compactMap { Int($0) }
        return days * 86400 + clock.reduce(0) { $0 * 60 + $1 }
    }

    /// Sends SIGTERM, then SIGKILL if the same process is still alive after a grace
    /// period. Returns false if the signal couldn't be sent, for example because
    /// another user owns the process.
    @discardableResult
    static func kill(_ pid: Int32, force: Bool = false) -> Bool {
        if force { return Darwin.kill(pid, SIGKILL) == 0 }
        let started = startTime(pid)
        guard Darwin.kill(pid, SIGTERM) == 0 else { return false }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            // Skip if the process exited and its PID now belongs to a new process.
            if let started, startTime(pid) == started { Darwin.kill(pid, SIGKILL) }
        }
        return true
    }

    /// Runs `docker stop` (or `kill`). Returns false when the CLI is missing, the daemon
    /// is down, or the container is gone, so the row can be restored with an alert.
    static func stopContainer(_ name: String, force: Bool = false) -> Bool {
        guard !name.isEmpty else { return false }
        let out = run("/usr/bin/env", ["docker", force ? "kill" : "stop", name], timeout: 15)
        return !out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Process start time, used to tell a process apart from a later one with the same PID.
    private static func startTime(_ pid: Int32) -> UInt64? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec
    }

    private final class Output { var data = Data() }

    /// Runs a command and returns its stdout. Kills it after `timeout` seconds so a hung
    /// `lsof`, `ps`, or unreachable Docker daemon can never stall the scan loop.
    static func run(_ path: String, _ args: [String], timeout: TimeInterval = 5) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return "" }

        // Read on a separate queue so a full pipe buffer can't deadlock the wait.
        let output = Output()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            output.data = pipe.fileHandleForReading.readDataToEndOfFile()
            done.signal()
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if done.wait(timeout: .now() + 1) == .timedOut {
                Darwin.kill(process.processIdentifier, SIGKILL)
            }
        }
        process.waitUntilExit()
        return String(decoding: output.data, as: UTF8.self)
    }
}
