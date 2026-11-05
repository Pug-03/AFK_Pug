import Foundation
import AppKit
import Carbon.HIToolbox
import CoreAudio
import ServiceManagement

// MARK: - Agents without hooks (Codex, Gemini CLI, Cursor Agent, ...)

/// Detects CLI agents by process and counts them as working while their
/// process tree uses CPU.
enum ProcessWatcher {
    static let known: [String: String] = [
        "codex": "Codex",
        "gemini": "Gemini CLI",
        "cursor-agent": "Cursor Agent",
        "aider": "Aider",
        "opencode": "OpenCode",
        "amp": "Amp",
        "goose": "Goose",
        "qwen": "Qwen Code",
    ]
    /// Runtimes that launch an agent script as their first non-flag argument.
    static let runtimes: Set<String> = ["node", "bun", "deno", "npx", "bunx", "uv", "uvx", "pipx", "python", "python3"]
    /// Process tree CPU % above which the agent counts as busy.
    static let busyCPU = 3.0

    /// A running agent process (top-level only) and its whole tree's CPU %.
    struct Found {
        let pid: Int32
        let display: String
        let cpu: Double
        var busy: Bool { cpu >= ProcessWatcher.busyCPU }
    }

    static func scan() -> [Found] {
        parse(sample(), ownPid: getpid())
    }

    /// `ps` output (or the simulator's fake process list).
    private static func sample() -> String {
        if Sim.enabled { return Sim.value("procs") ?? "" }
        // LC_ALL=C: with a comma-decimal locale ps prints "0,0" and nothing parses.
        return PowerControl.run("/usr/bin/env", ["LC_ALL=C", "/bin/ps", "-Ao", "pid=,ppid=,pcpu=,args="]).output
    }

    /// Per-pid CPU % and children, from one `ps` sample.
    struct Table {
        var cpu: [Int32: Double] = [:]
        var children: [Int32: [Int32]] = [:]

        /// CPU % of `pid` and all its descendants.
        func treeCPU(_ pid: Int32) -> Double {
            var total = 0.0
            var stack = [pid]
            var seen = Set<Int32>()
            while let p = stack.popLast(), seen.insert(p).inserted {
                total += cpu[p] ?? 0
                stack.append(contentsOf: children[p] ?? [])
            }
            return total
        }
    }

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cached: (at: Date, table: Table)?

    /// Is `pid`'s process tree busy (same threshold as agent detection)?
    /// Shares one `ps` sample for up to 10 s, so checking many holds stays cheap.
    static func treeBusy(_ pid: Int32) -> Bool {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        let now = Date()
        if cached == nil || now.timeIntervalSince(cached!.at) > 10 || Sim.enabled {
            cached = (now, table(sample()).0)
        }
        return cached!.table.treeCPU(pid) >= busyCPU
    }

    private static func table(_ out: String, ownPid: Int32 = -1) -> (Table, [(Int32, String)]) {
        var table = Table()
        var agents: [(Int32, String)] = []
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard parts.count == 4, let pid = Int32(parts[0]), let ppid = Int32(parts[1]), let pc = Double(parts[2]) else { continue }
            table.cpu[pid] = pc
            table.children[ppid, default: []].append(pid)
            if ownPid >= 0, pid != ownPid, let display = match(parts[3]) { agents.append((pid, display)) }
        }
        return (table, agents)
    }

    static func parse(_ out: String, ownPid: Int32) -> [Found] {
        let (table, agents) = table(out, ownPid: ownPid)

        // Skip agents nested inside another matched agent (e.g. node -> codex).
        let agentPids = Set(agents.map(\.0))
        var nested = Set<Int32>()
        for (pid, _) in agents {
            var stack = table.children[pid] ?? []
            while let c = stack.popLast() {
                if agentPids.contains(c) { nested.insert(c) }
                stack.append(contentsOf: table.children[c] ?? [])
            }
        }

        return agents.filter { !nested.contains($0.0) }.map { pid, display in
            Found(pid: pid, display: display, cpu: table.treeCPU(pid))
        }
    }

    /// Matches only the executable itself (`codex ...`) or a runtime running the
    /// agent script (`node /opt/homebrew/bin/codex`), never arbitrary arguments,
    /// so `grep amp`, `vim gemini` or `cd goose` don't count.
    static func match(_ args: Substring) -> String? {
        let tokens = args.split(separator: " ", omittingEmptySubsequences: true)
        guard let first = tokens.first else { return nil }
        // Desktop apps (Codex.app, Goose.app ...) are not the CLI agents.
        if first.contains(".app/Contents/") { return nil }
        let exe = baseName(first)
        if let display = known[exe] { return display }
        guard runtimes.contains(exe) || exe.hasPrefix("python3.") else { return nil }
        guard let script = tokens.dropFirst().prefix(3).first(where: { !$0.hasPrefix("-") }) else { return nil }
        // Installed packages: the package directory names the agent, whatever the entry file is called.
        for (marker, display) in packages where script.contains(marker) { return display }
        // A bin shim named after the agent (…/bin/codex, …/bin/gemini). A random
        // project file like ./amp.js or scripts/aider.py does not count.
        guard script.contains("/bin/") else { return nil }
        return known[baseName(script, stripExtension: false)]
    }

    /// Package directories of npm / pip installs.
    static let packages: [(String, String)] = [
        ("/@openai/codex/", "Codex"),
        ("/@google/gemini-cli/", "Gemini CLI"),
        ("/cursor-agent/", "Cursor Agent"),
        ("/@qwen-code/", "Qwen Code"),
        ("/opencode-ai/", "OpenCode"),
        ("/@sourcegraph/amp/", "Amp"),
        ("/aider-chat/", "Aider"),
        ("/site-packages/aider/", "Aider"),
    ]

    private static func baseName(_ token: Substring, stripExtension: Bool = false) -> String {
        // Case-sensitive: the CLIs are lowercase; "Codex" or "Goose" are app binaries.
        token.split(separator: "/").last.map(String.init) ?? ""
    }
}

// MARK: - Pause chat apps while the lid is closed

enum ChatPauser {
    static let apps = ["Slack", "Discord", "WhatsApp", "Telegram", "LINE", "Messenger", "Microsoft Teams"]
    static let file = Paths.state.appendingPathComponent("paused-pids")

    /// SIGSTOPs chat apps, except any app that is producing audio right now:
    /// that is a call (or a voice message), and stopping it would also end the
    /// audio that keeps the Mac awake.
    static func pause() {
        if Sim.enabled {
            // Sim: audio=chat means the audio comes from a chat app.
            if Sim.value("audio") == "chat" { Sim.record("chat apps left running (one is in a call)"); return }
            Sim.record("SIGSTOP chat apps")
            Paths.ensure()
            try? "sim".write(to: file, atomically: true, encoding: .utf8)
            return
        }
        let audible = AudioWatcher.outputPids()
        // Without per-process audio (macOS < 14.2) we can't tell who is playing: stay safe.
        if audible == nil, AudioWatcher.deviceRunning() { return }
        var pids: [Int32] = []
        for app in apps {
            let out = PowerControl.run("/usr/bin/pgrep", ["-f", "/Applications/\(app).app/"]).output
            let appPids = out.split(separator: "\n").compactMap { Int32($0) }
            if let audible, !audible.isDisjoint(with: appPids) { continue }
            pids += appPids
        }
        guard !pids.isEmpty else { return }
        Paths.ensure()
        try? pids.map(String.init).joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
        for pid in pids { kill(pid, SIGSTOP) }
    }

    static func resume() {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return }
        if Sim.enabled {
            Sim.record("SIGCONT chat apps")
            try? FileManager.default.removeItem(at: file)
            return
        }
        for pid in text.split(separator: "\n").compactMap({ Int32($0) }) { kill(pid, SIGCONT) }
        try? FileManager.default.removeItem(at: file)
    }

    /// PIDs we have stopped right now (they can't be playing audio).
    static func pausedPids() -> Set<pid_t> {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        return Set(text.split(separator: "\n").compactMap { pid_t($0) })
    }
}

// MARK: - Lock the screen

enum ScreenLock {
    /// Locks immediately, like ⌃⌘Q.
    static func lock() {
        if Sim.enabled { Sim.record("lock screen (SACLockScreenImmediate)"); return }
        typealias LockFn = @convention(c) () -> Int32
        if let handle = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_NOW),
           let symbol = dlsym(handle, "SACLockScreenImmediate") {
            _ = unsafeBitCast(symbol, to: LockFn.self)()
        } else {
            PowerControl.displaySleepNow()
        }
    }
}

// MARK: - Global shortcut ⌥⌘A

enum HotKey {
    private static var ref: EventHotKeyRef?
    private static var handlerInstalled = false
    static var action: (() -> Void)?

    static func setEnabled(_ on: Bool) {
        if on, ref == nil {
            if !handlerInstalled {
                var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
                InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                    DispatchQueue.main.async { HotKey.action?() }
                    return noErr
                }, 1, &spec, nil, nil)
                handlerInstalled = true
            }
            let id = EventHotKeyID(signature: OSType(0x4146_4B50), id: 1) // "AFKP"
            RegisterEventHotKey(UInt32(kVK_ANSI_A), UInt32(cmdKey | optionKey), id, GetApplicationEventTarget(), 0, &ref)
        } else if !on, let r = ref {
            UnregisterEventHotKey(r)
            ref = nil
        }
    }
}

// MARK: - Phone notifications (ntfy)

enum PhoneNotifier {
    static func send(topic: String, title: String, body: String) {
        let topic = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !topic.isEmpty, let url = URL(string: "https://ntfy.sh/") else { return }
        if Sim.enabled { Sim.record("ntfy \(topic): \(title) | \(body)"); return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload: [String: Any] = ["topic": topic, "title": title, "message": body, "tags": ["dog"]]
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        URLSession.shared.dataTask(with: request).resume()
    }
}

// MARK: - Triggers

enum Triggers {
    static func runningApp(from list: String) -> String? {
        let wanted = list.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
        guard !wanted.isEmpty else { return nil }
        if Sim.enabled, let fake = Sim.value("apps") {
            return fake.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.first { wanted.contains($0.lowercased()) }
        }
        for app in NSWorkspace.shared.runningApplications {
            if let name = app.localizedName, wanted.contains(name.lowercased()) { return name }
        }
        return nil
    }
}

// MARK: - MCP server (lets an agent ask AFK Pug to stay awake)

/// `AFKPug --mcp` speaks MCP over stdio. Tools write hold files that the app picks up.
enum MCPServer {
    static let supportedVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.2.0" }
    /// Holds made by this server process only, so one session's release can't drop another's.
    static var holdPrefix: String { "mcp-\(getpid())-" }

    static func run() {
        Paths.ensure()
        while let line = readLine(strippingNewline: true) {
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            guard let data = line.data(using: .utf8), let parsed = try? JSONSerialization.jsonObject(with: data) else {
                error(nil, -32700, "Parse error"); continue
            }
            guard let msg = parsed as? [String: Any] else {
                error(nil, -32600, "Invalid Request (batches are not supported)"); continue
            }
            let hasId = msg.keys.contains("id")
            let id = msg["id"]
            guard let method = msg["method"] as? String else {
                if hasId { error(validId(id) ? id : nil, -32600, "Invalid Request") }
                continue
            }
            guard hasId else { continue } // notifications need no reply
            guard validId(id) else { error(nil, -32600, "Invalid Request: id must be a string or number"); continue }
            let params = msg["params"] as? [String: Any] ?? [:]

            switch method {
            case "initialize":
                let asked = params["protocolVersion"] as? String ?? ""
                reply(id, result: [
                    "protocolVersion": supportedVersions.contains(asked) ? asked : "2025-06-18",
                    "capabilities": ["tools": [:]],
                    "serverInfo": ["name": "afkpug", "version": version],
                ])
            case "ping":
                reply(id, result: [:])
            case "tools/list":
                reply(id, result: ["tools": tools])
            case "tools/call":
                let name = params["name"] as? String ?? ""
                guard tools.contains(where: { $0["name"] as? String == name }) else {
                    error(id, -32602, "Unknown tool: \(name)"); continue
                }
                guard params["arguments"] == nil || params["arguments"] is [String: Any] else {
                    error(id, -32602, "arguments must be an object"); continue
                }
                let args = params["arguments"] as? [String: Any] ?? [:]
                let (text, failed) = call(name, args)
                var result: [String: Any] = ["content": [["type": "text", "text": text]]]
                if failed { result["isError"] = true }
                reply(id, result: result)
            default:
                error(id, -32601, "Method not found")
            }
        }
    }

    private static func validId(_ id: Any?) -> Bool {
        guard let id else { return false }
        if id is String { return true }
        if let n = id as? NSNumber { return CFGetTypeID(n) != CFBooleanGetTypeID() }
        return false
    }

    private static let tools: [[String: Any]] = [
        [
            "name": "keep_mac_awake",
            "description": "Keep this Mac awake (even with the lid closed) for a while, e.g. during a long build, test run or deploy that continues after your reply.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "minutes": ["type": "integer", "description": "How long to stay awake, 1-720", "minimum": 1, "maximum": 720],
                    "reason": ["type": "string", "description": "Short reason shown to the user (max 200 characters)"],
                ],
                "required": ["minutes"],
            ],
        ],
        [
            "name": "release_mac_awake",
            "description": "Stop keeping the Mac awake for holds this session created with keep_mac_awake.",
            "inputSchema": ["type": "object", "properties": [:]],
        ],
        [
            "name": "afk_status",
            "description": "Show what is currently keeping the Mac awake.",
            "inputSchema": ["type": "object", "properties": [:]],
            "annotations": ["readOnlyHint": true],
        ],
    ]

    /// Returns the text and whether it is a tool error (so the model can correct itself).
    private static func call(_ name: String, _ args: [String: Any]) -> (String, Bool) {
        switch name {
        case "keep_mac_awake":
            guard let number = args["minutes"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
                return ("minutes is required and must be a number from 1 to 720.", true)
            }
            let raw = number.doubleValue
            guard raw.isFinite, raw >= 1, raw <= 720 else { return ("minutes must be from 1 to 720.", true) }
            let minutes = Int(raw.rounded())
            var reason = "agent"
            if let value = args["reason"] {
                guard let text = value as? String else { return ("reason must be a string.", true) }
                let clean = String(text.unicodeScalars.filter { $0.value >= 0x20 && $0 != "\"" && $0 != "\\" }.prefix(200).map(Character.init))
                if !clean.trimmingCharacters(in: .whitespaces).isEmpty { reason = clean }
            }
            let now = Date().timeIntervalSince1970
            let id = holdPrefix + "\(Int(now))-\(Int.random(in: 1000...9999))"
            let json: [String: Any] = ["agent": "cli", "started": now, "expires": now + Double(minutes * 60), "reason": reason]
            guard let data = try? JSONSerialization.data(withJSONObject: json),
                  (try? data.write(to: Paths.holds.appendingPathComponent(id))) != nil else {
                return ("Could not write the hold file in ~/.afkpug/holds.", true)
            }
            let running = AppPresence.appRunning()
            return ("Keeping the Mac awake for \(minutes) minutes (\(reason))." + (running ? "" : " Note: the AFK Pug app is not running, so this has no effect until it starts."), false)
        case "release_mac_awake":
            let files = (try? FileManager.default.contentsOfDirectory(atPath: Paths.holds.path)) ?? []
            let mine = files.filter { $0.hasPrefix(holdPrefix) }
            for f in mine { try? FileManager.default.removeItem(at: Paths.holds.appendingPathComponent(f)) }
            return ("Released \(mine.count) hold(s).", false)
        case "afk_status":
            let holds = HoldStore.scan()
            let app = AppPresence.appRunning() ? "AFK Pug is running." : "AFK Pug is not running."
            if holds.isEmpty { return (app + " Nothing is holding the Mac awake right now.", false) }
            let lines = holds.map { hold -> String in
                guard let until = hold.expires else { return "- \(hold.displayName)" }
                let sameDay = Calendar.current.isDateInToday(until)
                return "- \(hold.displayName) until \(until.formatted(date: sameDay ? .omitted : .abbreviated, time: .shortened))"
            }
            return (([app] + lines).joined(separator: "\n"), false)
        default:
            return ("Unknown tool \(name)", true)
        }
    }

    private static func reply(_ id: Any?, result: [String: Any]) {
        send(["jsonrpc": "2.0", "id": id ?? NSNull(), "result": result])
    }

    private static func error(_ id: Any?, _ code: Int, _ message: String) {
        send(["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": code, "message": message]])
    }

    private static func send(_ object: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]) else { return }
        data.append(0x0A)
        FileHandle.standardOutput.write(data)
    }
}

/// Is the menu bar app running? `pgrep -x AFKPug` is not enough: every
/// `AFKPug --mcp` server Claude Code spawns has the same process name.
enum AppPresence {
    static func appRunning() -> Bool {
        let out = PowerControl.run("/bin/ps", ["-Ao", "pid=,args="]).output
        let me = getpid()
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2, let pid = Int32(parts[0]), pid != me else { continue }
            let args = parts[1]
            let exe = args.split(separator: " ").first.map { $0.split(separator: "/").last ?? "" } ?? ""
            if exe == "AFKPug", !args.contains("--mcp") { return true }
        }
        return false
    }
}

/// Registers the MCP server with Claude Code (user scope). Runs `claude`, so
/// call it off the main thread.
enum MCPInstaller {
    static var executable: String { Bundle.main.executablePath ?? CommandLine.arguments[0] }
    static var configURL: URL { ConfigFile.home(".claude.json") }

    /// The AFK Pug Claude Code plugin is installed and brings its own MCP server
    /// (plugin/.mcp.json): a user-scope registration would list the tools twice.
    static var providedByPlugin: Bool { ClaudeHooks.pluginInstalled() }

    /// The user-scope "afkpug" server in ~/.claude.json, and the command it runs.
    static func registeredCommand() -> String? {
        guard let data = try? Data(contentsOf: configURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = json["mcpServers"] as? [String: Any],
              let server = servers["afkpug"] as? [String: Any] else { return nil }
        return server["command"] as? String ?? ""
    }

    static func isInstalled() -> Bool { registeredCommand() != nil }

    /// Registered, but for a different copy of the app (moved, rebuilt elsewhere).
    static func needsRefresh() -> Bool {
        guard let command = registeredCommand(), !Sim.enabled else { return false }
        return command != executable && !executable.contains("/AppTranslocation/")
    }

    enum Failure: Error { case noClaude, translocated, failed(String) }

    static func install() -> Result<Void, Failure> {
        if Sim.enabled {
            if Sim.value("claude") == "missing" { Sim.record("claude not found"); return .failure(.noClaude) }
            Sim.record("claude mcp add --scope user afkpug (skipped)")
            return .success(())
        }
        // A quarantined app runs from a random read-only copy that disappears later.
        if executable.contains("/AppTranslocation/") { return .failure(.translocated) }
        guard let claude = findClaude() else { return .failure(.noClaude) }
        _ = runClaude(claude, ["mcp", "remove", "--scope", "user", "afkpug"])
        let result = runClaude(claude, ["mcp", "add", "--scope", "user", "afkpug", "--", executable, "--mcp"])
        return result.status == 0 ? .success(()) : .failure(.failed(result.output.trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    @discardableResult
    static func uninstall() -> Bool {
        if Sim.enabled { Sim.record("claude mcp remove --scope user afkpug (skipped)"); return true }
        guard let claude = findClaude() else { return false }
        return runClaude(claude, ["mcp", "remove", "--scope", "user", "afkpug"]).status == 0
    }

    /// GUI apps don't get the shell's PATH, so ask an interactive login zsh
    /// first, then look in the usual install locations.
    static func findClaude() -> String? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        // Known install locations first (fast, no shell rc files involved).
        var candidates = ["\(home)/.local/bin/claude", "\(home)/.claude/local/claude",
                          "/opt/homebrew/bin/claude", "/usr/local/bin/claude",
                          "\(home)/.volta/bin/claude", "\(home)/.bun/bin/claude",
                          "\(home)/.npm-global/bin/claude", "\(home)/.asdf/shims/claude",
                          "\(home)/.local/share/mise/shims/claude"]
        func versioned(_ dir: String, _ tail: String) -> [String] {
            ((try? fm.contentsOfDirectory(atPath: dir)) ?? [])
                .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
                .map { "\(dir)/\($0)/\(tail)" }
        }
        candidates += versioned("\(home)/.nvm/versions/node", "bin/claude")
        candidates += versioned("\(home)/.local/share/mise/installs/node", "bin/claude")
        candidates += versioned("\(home)/Library/Application Support/fnm/node-versions", "installation/bin/claude")
        if let found = candidates.first(where: { fm.isExecutableFile(atPath: $0) }) { return found }
        // Last resort: ask an interactive login shell (may read slow rc files; capped at 10 s).
        return run("/bin/zsh", ["-ilc", "command -v claude"], timeout: 10).output
            .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .last { $0.hasPrefix("/") && fm.isExecutableFile(atPath: $0) }
    }

    /// `claude` is usually a node script: put its own folder (where nvm keeps
    /// node) and the Homebrew paths on PATH.
    private static func runClaude(_ claude: String, _ args: [String]) -> (status: Int32, output: String) {
        let dir = (claude as NSString).deletingLastPathComponent
        let path = [dir, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", ProcessInfo.processInfo.environment["PATH"] ?? ""]
            .filter { !$0.isEmpty }.joined(separator: ":")
        return run(claude, args, env: ["PATH": path], timeout: 60)
    }

    private static func run(_ path: String, _ args: [String], env: [String: String] = [:], timeout: TimeInterval) -> (status: Int32, output: String) {
        if Sim.enabled { Sim.record("BLOCKED exec \(path) \(args.joined(separator: " "))"); return (-1, "") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        process.environment = ProcessInfo.processInfo.environment.merging(env) { $1 }
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (-1, "") }
        // A shell rc file that waits for input must not hang us forever.
        let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        killer.cancel()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

// MARK: - Is audio playing?

enum AudioWatcher {
    /// True when another app is sending audio out (music, YouTube, a call).
    /// Our own sounds and chat apps we have SIGSTOPped never count.
    /// Note: an app that keeps an output stream open while silent still counts;
    /// CoreAudio can't tell silence from music.
    static func isPlaying() -> Bool {
        if let fake = Sim.value("audio") {
            // A chat app we stopped can't play: models the real pid subtraction below.
            if fake == "chat" { return !FileManager.default.fileExists(atPath: ChatPauser.file.path) }
            return fake == "playing"
        }
        var ignored = ChatPauser.pausedPids()
        ignored.insert(getpid())
        if let pids = outputPids() {
            return !pids.subtracting(ignored).isEmpty
        }
        return deviceRunning()
    }

    /// Names of the apps producing sound right now (for the UI), best effort.
    static func playingApps() -> [String] {
        if let fake = Sim.value("audio") { return fake == "silent" ? [] : (fake == "chat" ? ["Slack"] : ["Music"]) }
        var ignored = ChatPauser.pausedPids()
        ignored.insert(getpid())
        guard let pids = outputPids()?.subtracting(ignored) else { return [] }
        var names: [String] = []
        for pid in pids.sorted() {
            if let app = NSRunningApplication(processIdentifier: pid), let name = app.localizedName {
                if !names.contains(name) { names.append(name) }
                continue
            }
            // Helper processes: "Google Chrome Helper (Renderer)" -> "Google Chrome".
            var buffer = [CChar](repeating: 0, count: 256)
            guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { continue }
            var name = String(cString: buffer)
            if let r = name.range(of: " Helper") { name = String(name[..<r.lowerBound]) }
            if name.hasPrefix("com.apple.WebKit") { name = "Safari" }
            if !name.isEmpty, !names.contains(name) { names.append(name) }
        }
        return names
    }

    /// PIDs with running audio output, nil before macOS 14.2.
    static func outputPids() -> Set<pid_t>? {
        guard #available(macOS 14.2, *) else { return nil }
        return processOutputPids()
    }

    @available(macOS 14.2, *)
    private static func processOutputPids() -> Set<pid_t>? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return nil }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &objects) == noErr else { return nil }
        var result = Set<pid_t>()
        for object in objects {
            var running: UInt32 = 0
            var runningSize = UInt32(MemoryLayout<UInt32>.size)
            address.mSelector = kAudioProcessPropertyIsRunningOutput
            guard AudioObjectGetPropertyData(object, &address, 0, nil, &runningSize, &running) == noErr, running != 0 else { continue }
            var pid: pid_t = 0
            var pidSize = UInt32(MemoryLayout<pid_t>.size)
            address.mSelector = kAudioProcessPropertyPID
            if AudioObjectGetPropertyData(object, &address, 0, nil, &pidSize, &pid) == noErr { result.insert(pid) }
        }
        return result
    }

    static func deviceRunning() -> Bool {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr else { return false }
        var running: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        address.mSelector = kAudioDevicePropertyDeviceIsRunningSomewhere
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &running) == noErr else { return false }
        return running != 0
    }
}

// MARK: - Launch at login

enum LoginItem {
    enum State { case on, off, needsApproval }

    static var state: State {
        if Sim.enabled { return Sim.value("login") == "on" ? .on : .off }
        switch SMAppService.mainApp.status {
        case .enabled: return .on
        case .requiresApproval: return .needsApproval
        default: return .off
        }
    }

    static func set(_ on: Bool) throws {
        if Sim.enabled { Sim.record("login item \(on ? "on" : "off")"); Sim.set("login", on ? "on" : "off"); return }
        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}
