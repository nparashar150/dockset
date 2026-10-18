import AppKit
import Darwin
import Observation

/// One coding agent running on this Mac.
struct RunningAgent: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable {
        case cli, app
    }

    var id: pid_t
    var kind: Kind
    /// "Claude", "Codex", "Cursor".
    var name: String
    /// The folder it was started in, nil for an app.
    var directory: String?
    /// The app it runs inside: Terminal, iTerm, VS Code, or the agent's own.
    var host: String
    var hostBundleID: String?
    var hostPID: pid_t?
    /// The terminal device, for finding its tab, e.g. "/dev/ttys012".
    var tty: String?
    var started: Date
    /// Busy: from the agent's own status where it publishes one, from its
    /// processor use otherwise.
    var working: Bool
    /// What this session was last asked, its last answer, and when it last
    /// changed: read from its own log, for agents that keep one.
    var lastPrompt: String?
    var lastReply: String?
    var updated: Date?

    /// The line that says what the session is: what it was asked, or where
    /// it is when there is nothing to go on.
    var headline: String { lastPrompt ?? (kind == .app ? name : "\(name) in \(project)") }

    var project: String {
        directory.map { URL(fileURLWithPath: $0).lastPathComponent } ?? name
    }

    /// Whether a typed message can be put into its session. Only Terminal and
    /// iTerm can address one tab from outside; everything else can only be
    /// brought forward.
    var canSend: Bool {
        tty != nil && (hostBundleID == AgentScanner.terminal || hostBundleID == AgentScanner.iTerm)
    }
}

/// Finds the coding agents running on this Mac, and where.
///
/// Read straight from the kernel's process table with libproc: the
/// executable, its arguments, its working directory, its terminal and its
/// processor time, for the person's own processes only. No subprocess, no
/// permission. Only runs while something on screen asks it to, every few
/// seconds while the Ask panel is open and rarely for the tile's count.
@MainActor @Observable
final class AgentScanner {
    static let shared = AgentScanner()

    nonisolated static let terminal = "com.apple.Terminal"
    nonisolated static let iTerm = "com.googlecode.iterm2"

    private(set) var agents: [RunningAgent] = []

    @ObservationIgnored private var lastCPU: [pid_t: (time: UInt64, at: Date)] = [:]
    @ObservationIgnored private var scanning = false

    private init() {}

    var working: Int { agents.filter(\.working).count }

    /// Working first, then the most recently active.
    var sorted: [RunningAgent] {
        agents.sorted {
            if $0.working != $1.working { return $0.working }
            return ($0.updated ?? $0.started) > ($1.updated ?? $1.started)
        }
    }

    func refresh() async {
        guard !scanning else { return }
        scanning = true
        defer { scanning = false }
        let previous = lastCPU
        let found = await Task.detached(priority: .utility) { Self.scan(previous: previous) }.value
        lastCPU = found.cpu
        agents = found.agents + Self.apps()
    }

    /// A line per agent, for a question asked about them.
    var summary: String {
        guard !agents.isEmpty else { return "No coding agents are running on this Mac." }
        let lines = agents.map { agent -> String in
            var parts = ["\(agent.name) in \(agent.directory ?? "its own app")", "in \(agent.host)",
                         "running \(Self.age(agent.started))", agent.working ? "working" : "idle"]
            if let updated = agent.updated { parts.append("last active \(Self.age(updated)) ago") }
            if let prompt = agent.lastPrompt { parts.append("last asked: \"\(prompt.prefix(140))\"") }
            if let reply = agent.lastReply { parts.append("last replied: \"\(reply.prefix(140))\"") }
            return "- " + parts.joined(separator: ", ")
        }
        return "Coding agents running on this Mac right now:\n" + lines.joined(separator: "\n")
    }

    static func age(_ date: Date) -> String {
        let seconds = max(0, Date().timeIntervalSince(date))
        if seconds < 60 { return "\(Int(seconds))s" }
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        if seconds < 86400 { return "\(Int(seconds / 3600))h" }
        return "\(Int(seconds / 86400))d"
    }

    // MARK: Command-line agents

    /// Executable names that are agents, and what to call them. An agent
    /// written in JavaScript runs as `node …/bin/codex`, so the script's name
    /// is looked at too.
    nonisolated private static let known: [String: String] = [
        "claude": "Claude", "codex": "Codex", "gemini": "Gemini", "opencode": "OpenCode",
        "cursor-agent": "Cursor Agent", "aider": "Aider", "goose": "Goose", "crush": "Crush",
        "amp": "Amp", "qwen": "Qwen", "droid": "Droid", "pi": "Pi", "kimi": "Kimi",
    ]

    nonisolated private static let interpreters: Set<String> = ["node", "bun", "deno", "python", "python3"]

    /// Arguments that mark a run that is not an interactive session: a
    /// one-shot `-p`, which is also how Ask itself asks, a browser bridge, an
    /// MCP server.
    nonisolated private static let headless: Set<String> = ["-p", "--print", "--chrome-native-host", "mcp", "exec"]

    nonisolated private static func scan(previous: [pid_t: (time: UInt64, at: Date)])
        -> (agents: [RunningAgent], cpu: [pid_t: (time: UInt64, at: Date)]) {
        let uid = getuid()
        let now = Date()
        var parents: [pid_t: pid_t] = [:]
        var mine: [pid_t: proc_bsdinfo] = [:]
        for pid in allPIDs() {
            // From sysctl, which answers for every process: a root-owned
            // `login` sits between Terminal and the shell, and libproc
            // refuses to describe it, which broke the walk up to the app.
            if let parent = parent(of: pid) { parents[pid] = parent }
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { continue }
            if info.pbi_uid == uid { mine[pid] = info }
        }

        var cpu: [pid_t: (time: UInt64, at: Date)] = [:]
        var candidates: [(pid: pid_t, name: String, info: proc_bsdinfo)] = []
        for (pid, info) in mine {
            guard let name = agentName(pid) else { continue }
            candidates.append((pid, name, info))
        }
        let agentPIDs = Set(candidates.map(\.pid))

        var agents: [RunningAgent] = []
        for candidate in candidates {
            // A helper an agent started is part of that agent, not another.
            if let parent = parents[candidate.pid], agentPIDs.contains(parent) { continue }
            let total = cpuTime(candidate.pid)
            if let total { cpu[candidate.pid] = (total, now) }
            var working = false
            if let before = previous[candidate.pid], let total, total >= before.time {
                let elapsed = now.timeIntervalSince(before.at)
                // Nanoseconds of processor per second of wall time, as a
                // fraction: above 3% it is doing something, below it is
                // sitting at a prompt.
                working = elapsed > 0 && Double(total - before.time) / 1e9 / elapsed > 0.03
            }
            let host = hostApp(of: candidate.pid, parents: parents)
            var agent = RunningAgent(
                id: candidate.pid, kind: .cli, name: candidate.name,
                directory: workingDirectory(candidate.pid),
                host: host?.localizedName ?? "a terminal",
                hostBundleID: host?.bundleIdentifier, hostPID: host?.processIdentifier,
                tty: ttyPath(candidate.info),
                started: Date(timeIntervalSince1970: TimeInterval(candidate.info.pbi_start_tvsec)),
                working: working)
            if candidate.name == "Claude" { readClaudeSession(into: &agent) }
            agents.append(agent)
        }
        return (agents.sorted { $0.started > $1.started }, cpu)
    }

    nonisolated private static func agentName(_ pid: pid_t) -> String? {
        let arguments = self.arguments(pid)
        guard let first = arguments.first else { return nil }
        let executable = URL(fileURLWithPath: first).lastPathComponent
        var name = known[executable]
        if name == nil, interpreters.contains(executable), arguments.count > 1 {
            name = known[URL(fileURLWithPath: arguments[1]).lastPathComponent]
        }
        guard let name else { return nil }
        if arguments.dropFirst().contains(where: headless.contains) { return nil }
        return name
    }

    nonisolated private static func parent(of pid: pid_t) -> pid_t? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }

    nonisolated private static func allPIDs() -> [pid_t] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) * 2)
        let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        return Array(pids.prefix(Int(max(0, filled))))
    }

    /// argv, from the kernel's copy: the executable path, then each argument.
    nonisolated private static func arguments(_ pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return [] }
        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        // After argc: the executable path, padding NULs, then argv.
        var parts: [String] = []
        var index = MemoryLayout<Int32>.size
        var start = index
        var skippingPath = true
        while index < size, parts.count < Int(argc) {
            if buffer[index] == 0 {
                if skippingPath {
                    skippingPath = false
                    while index + 1 < size, buffer[index + 1] == 0 { index += 1 }
                } else {
                    parts.append(String(decoding: buffer[start ..< index], as: UTF8.self))
                }
                start = index + 1
            }
            index += 1
        }
        return parts
    }

    nonisolated private static func workingDirectory(_ pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return path.isEmpty ? nil : path
    }

    /// User plus system processor time, in nanoseconds.
    nonisolated private static func cpuTime(_ pid: pid_t) -> UInt64? {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size else { return nil }
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let ticks = info.pti_total_user + info.pti_total_system
        return ticks * UInt64(timebase.numer) / UInt64(max(timebase.denom, 1))
    }

    nonisolated private static func ttyPath(_ info: proc_bsdinfo) -> String? {
        let raw = info.e_tdev
        guard raw != UInt32.max, raw != 0,
              let name = devname(dev_t(bitPattern: raw), mode_t(S_IFCHR)) else { return nil }
        let text = String(cString: name)
        return text.hasPrefix("ttys") ? "/dev/" + text : nil
    }

    /// The first app up the process tree: the terminal or editor this runs in.
    nonisolated private static func hostApp(of pid: pid_t, parents: [pid_t: pid_t]) -> NSRunningApplication? {
        var current = parents[pid]
        var hops = 0
        while let pid = current, pid > 1, hops < 12 {
            if let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular {
                return app
            }
            current = parents[pid]
            hops += 1
        }
        return nil
    }

    // MARK: Apps

    /// Agent apps, by name: they have no folder or terminal to show, only
    /// that they are open, and Focus brings them forward.
    private static let agentApps: Set<String> = [
        "Antigravity", "Cursor", "Kiro", "Windsurf", "Claude", "ChatGPT", "Codex", "Zed", "Trae",
    ]

    private static func apps() -> [RunningAgent] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.activationPolicy == .regular, let name = app.localizedName,
                  agentApps.contains(name) else { return nil }
            return RunningAgent(id: app.processIdentifier, kind: .app, name: name, directory: nil,
                                host: name, hostBundleID: app.bundleIdentifier,
                                hostPID: app.processIdentifier, tty: nil,
                                started: app.launchDate ?? Date(), working: false)
        }
    }

    // MARK: Session logs

    /// Claude publishes a small file per running session, named by process:
    /// its session, folder and a status it keeps current itself. That gives
    /// this session its own log rather than whichever is newest in the
    /// folder, and "busy" from the agent rather than guessed from the
    /// processor.
    nonisolated private static func readClaudeSession(into agent: inout RunningAgent) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let meta = home.appending(path: ".claude/sessions/\(agent.id).json")
        guard let data = try? Data(contentsOf: meta),
              let session = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let status = session["status"] as? String { agent.working = status != "idle" }
        if let updated = session["updatedAt"] as? Double {
            agent.updated = Date(timeIntervalSince1970: updated / 1000)
        }
        guard let id = session["sessionId"] as? String,
              let directory = (session["cwd"] as? String) ?? agent.directory else { return }
        let folder = directory.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ".", with: "-")
        let log = home.appending(path: ".claude/projects/\(folder)/\(id).jsonl")
        let (prompt, reply) = lastTurn(in: log)
        agent.lastPrompt = prompt
        agent.lastReply = reply
    }

    /// The last thing typed and the last thing answered, from the tail of a
    /// session log only, so a long session costs the same as a short one.
    nonisolated private static func lastTurn(in url: URL) -> (prompt: String?, reply: String?) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return (nil, nil) }
        defer { try? handle.close() }
        let end = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: end > 524_288 ? end - 524_288 : 0)
        let text = String(decoding: handle.readDataToEndOfFile(), as: UTF8.self)
        var prompt: String?
        var reply: String?
        for line in text.split(separator: "\n").reversed() where prompt == nil {
            let isUser = line.contains("\"type\":\"user\"")
            let isAssistant = line.contains("\"type\":\"assistant\"")
            guard isUser || (isAssistant && reply == nil),
                  let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let message = object["message"] as? [String: Any] else { continue }
            if isUser {
                // Plain text, or parts when the message carried an image;
                // a tool's result comes back as parts with no text in them.
                let content = (message["content"] as? String)
                    ?? (message["content"] as? [[String: Any]])?
                        .compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
                        .joined(separator: " ")
                    ?? ""
                let clean = oneLine(content)
                // Commands and tool output are logged as user turns too.
                if !clean.isEmpty, !clean.hasPrefix("<") { prompt = clean }
            } else if isAssistant, let parts = message["content"] as? [[String: Any]] {
                let said = parts.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
                    .joined(separator: " ")
                let clean = oneLine(said)
                if !clean.isEmpty { reply = clean }
            }
        }
        return (prompt, reply)
    }

    nonisolated private static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    // MARK: Actions

    /// Brings the agent's own tab forward where that can be done, its app
    /// otherwise.
    static func focus(_ agent: RunningAgent) {
        if let tty = agent.tty, agent.hostBundleID == terminal {
            run("""
            tell application id "\(terminal)"
                repeat with w in windows
                    repeat with t in tabs of w
                        if tty of t is "\(tty)" then
                            set selected of t to true
                            set index of w to 1
                        end if
                    end repeat
                end repeat
                activate
            end tell
            """)
        } else if let tty = agent.tty, agent.hostBundleID == iTerm {
            run("""
            tell application id "\(iTerm)"
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            if tty of s is "\(tty)" then
                                select w
                                tell t to select
                                tell s to select
                            end if
                        end repeat
                    end repeat
                end repeat
                activate
            end tell
            """)
        } else if let pid = agent.hostPID {
            NSRunningApplication(processIdentifier: pid)?.activate()
        }
    }

    /// Types `text` into the agent's session and presses Return, as if typed
    /// there. Only for a Terminal or iTerm tab; see `canSend`.
    static func send(_ text: String, to agent: RunningAgent) {
        guard agent.canSend, let tty = agent.tty else { return }
        let literal = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        if agent.hostBundleID == terminal {
            run("""
            tell application id "\(terminal)"
                repeat with w in windows
                    repeat with t in tabs of w
                        if tty of t is "\(tty)" then do script "\(literal)" in t
                    end repeat
                end repeat
            end tell
            """)
        } else {
            run("""
            tell application id "\(iTerm)"
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            if tty of s is "\(tty)" then tell s to write text "\(literal)"
                        end repeat
                    end repeat
                end repeat
            end tell
            """)
        }
    }

    /// One serial queue: `NSAppleScript` is not documented as thread-safe.
    private static let scripts = DispatchQueue(label: "com.namanparashar.plinth.agents")

    private static func run(_ source: String) {
        scripts.async {
            var error: NSDictionary?
            NSAppleScript(source: source)?.executeAndReturnError(&error)
        }
    }
}
