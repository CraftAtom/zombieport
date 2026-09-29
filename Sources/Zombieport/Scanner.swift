import Foundation

struct DevProcess: Identifiable, Equatable {
    let pid: Int32
    let command: String
    let args: String
    let cwd: String?
    let ports: [Int]
    let uptimeSeconds: Int
    let projectName: String
    let repoName: String?
    let script: String

    var id: Int32 { pid }
    var firstPort: Int { ports.first ?? 0 }
    var portsLabel: String { ports.map(String.init).joined(separator: ", ") }

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
        guard let cwd else { return "unknown location" }
        let home = NSHomeDirectory()
        return cwd == home || cwd.hasPrefix(home + "/") ? "~" + cwd.dropFirst(home.count) : cwd
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
        // pid -> (command, ports)
        var listeners: [Int32: (command: String, ports: Set<Int>)] = [:]
        var currentPid: Int32?
        for line in run("/usr/sbin/lsof", ["+c", "0", "-nP", "-iTCP", "-sTCP:LISTEN", "-F", "pcn"])
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
        guard !pids.isEmpty else { return [] }
        let pidList = pids.map(String.init).joined(separator: ",")

        // Working directories.
        var cwds: [Int32: String] = [:]
        currentPid = nil
        for line in run("/usr/sbin/lsof", ["-a", "-d", "cwd", "-p", pidList, "-F", "pn"]).split(separator: "\n") {
            let value = String(line.dropFirst())
            if line.first == "p" { currentPid = Int32(value) }
            if line.first == "n", let pid = currentPid { cwds[pid] = value }
        }

        // Uptime and full command line.
        var info: [Int32: (uptime: String, args: String)] = [:]
        for line in run("/bin/ps", ["-o", "pid=,etime=,args=", "-p", pidList]).split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3, let pid = Int32(parts[0]) else { continue }
            info[pid] = (String(parts[1]), String(parts[2]))
        }

        return pids.compactMap { pid in
            guard let l = listeners[pid] else { return nil }
            return DevProcess(
                pid: pid,
                command: l.command,
                args: info[pid]?.args ?? l.command,
                cwd: cwds[pid],
                ports: l.ports.sorted(),
                uptimeSeconds: parseElapsed(info[pid]?.uptime ?? ""),
                projectName: DevProcess.projectName(cwd: cwds[pid], command: l.command),
                repoName: DevProcess.repoName(cwd: cwds[pid]),
                script: DevProcess.script(args: info[pid]?.args ?? "", command: l.command)
            )
        }
        .sorted { ($0.ports.first ?? 0) < ($1.ports.first ?? 0) }
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

    /// Process start time, used to tell a process apart from a later one with the same PID.
    private static func startTime(_ pid: Int32) -> UInt64? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec
    }

    private static func run(_ path: String, _ args: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
