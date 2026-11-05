import Foundation
import AppKit
import Carbon.HIToolbox
import CoreAudio

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
        return PowerControl.run("/bin/ps", ["-Ao", "pid=,ppid=,pcpu=,args="]).output
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
        let exe = baseName(first)
        if let display = known[exe] { return display }
        guard runtimes.contains(exe) || exe.hasPrefix("python3.") else { return nil }
        guard let script = tokens.dropFirst().prefix(3).first(where: { !$0.hasPrefix("-") }) else { return nil }
        return known[baseName(script)]
    }

    private static func baseName(_ token: Substring) -> String {
        var name = (token.split(separator: "/").last.map(String.init) ?? "").lowercased()
        for ext in [".js", ".mjs", ".cjs", ".py"] where name.hasSuffix(ext) { name.removeLast(ext.count) }
        return name
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
    static func run() {
        Paths.ensure()
        while let line = readLine(strippingNewline: true) {
            guard let data = line.data(using: .utf8),
                  let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let method = msg["method"] as? String else { continue }
            let id = msg["id"]
            let params = msg["params"] as? [String: Any] ?? [:]
            guard id != nil else { continue } // notifications need no reply

            switch method {
            case "initialize":
                reply(id, result: [
                    "protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
                    "capabilities": ["tools": [:]],
                    "serverInfo": ["name": "afkpug", "version": "0.2.0"],
                ])
            case "ping":
                reply(id, result: [:])
            case "tools/list":
                reply(id, result: ["tools": tools])
            case "tools/call":
                let name = params["name"] as? String ?? ""
                let args = params["arguments"] as? [String: Any] ?? [:]
                reply(id, result: ["content": [["type": "text", "text": call(name, args)]]])
            default:
                send(["jsonrpc": "2.0", "id": id!, "error": ["code": -32601, "message": "Method not found"]])
            }
        }
    }

    private static let tools: [[String: Any]] = [
        [
            "name": "keep_mac_awake",
            "description": "Keep this Mac awake (even with the lid closed) for a while, e.g. during a long build, test run or deploy that continues after your reply.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "minutes": ["type": "integer", "description": "How long to stay awake, 1-720", "minimum": 1, "maximum": 720],
                    "reason": ["type": "string", "description": "Short reason shown to the user"],
                ],
                "required": ["minutes"],
            ],
        ],
        [
            "name": "release_mac_awake",
            "description": "Stop keeping the Mac awake for holds created by this tool.",
            "inputSchema": ["type": "object", "properties": [:]],
        ],
        [
            "name": "afk_status",
            "description": "Show what is currently keeping the Mac awake.",
            "inputSchema": ["type": "object", "properties": [:]],
        ],
    ]

    private static func call(_ name: String, _ args: [String: Any]) -> String {
        switch name {
        case "keep_mac_awake":
            // Clamp as a Double first: Int(1e300) or Int(.nan) would trap.
            let raw = (args["minutes"] as? NSNumber)?.doubleValue ?? Double(args["minutes"] as? String ?? "") ?? 30
            let minutes = raw.isNaN ? 30 : Int(min(720, max(1, raw)).rounded())
            let reason = (args["reason"] as? String ?? "agent").replacingOccurrences(of: "\"", with: "")
            let now = Date().timeIntervalSince1970
            let id = "mcp-\(Int(now))-\(Int.random(in: 1000...9999))"
            let json: [String: Any] = ["agent": "cli", "started": now, "expires": now + Double(minutes * 60), "reason": reason]
            if let data = try? JSONSerialization.data(withJSONObject: json) {
                try? data.write(to: Paths.holds.appendingPathComponent(id))
            }
            let running = AppPresence.appRunning()
            return "Keeping the Mac awake for \(minutes) minutes (\(reason))." + (running ? "" : " Note: the AFK Pug app is not running, so this has no effect until it starts.")
        case "release_mac_awake":
            let files = (try? FileManager.default.contentsOfDirectory(atPath: Paths.holds.path)) ?? []
            let mine = files.filter { $0.hasPrefix("mcp-") }
            for f in mine { try? FileManager.default.removeItem(at: Paths.holds.appendingPathComponent(f)) }
            return "Released \(mine.count) hold(s)."
        case "afk_status":
            let holds = HoldStore.scan()
            if holds.isEmpty { return "Nothing is holding the Mac awake right now." }
            return holds.map { "- \($0.displayName)" + ($0.expires.map { " until \($0.formatted(date: .omitted, time: .shortened))" } ?? "") }
                .joined(separator: "\n")
        default:
            return "Unknown tool \(name)"
        }
    }

    private static func reply(_ id: Any?, result: [String: Any]) {
        send(["jsonrpc": "2.0", "id": id ?? NSNull(), "result": result])
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

    static func isInstalled() -> Bool {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
        return text.contains("\"afkpug\"")
    }

    enum Failure: Error { case noClaude, failed(String) }

    static func install() -> Result<Void, Failure> {
        if Sim.enabled {
            if Sim.value("claude") == "missing" { Sim.record("claude not found"); return .failure(.noClaude) }
            Sim.record("claude mcp add --scope user afkpug (skipped)")
            return .success(())
        }
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
        let fromShell = run("/bin/zsh", ["-ilc", "command -v claude"], timeout: 10).output
            .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .last { $0.hasPrefix("/") && fm.isExecutableFile(atPath: $0) }
        if let fromShell { return fromShell }
        var candidates = ["\(home)/.local/bin/claude", "\(home)/.claude/local/claude",
                          "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        let nvm = "\(home)/.nvm/versions/node"
        let versions = ((try? fm.contentsOfDirectory(atPath: nvm)) ?? [])
            .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
        candidates += versions.map { "\(nvm)/\($0)/bin/claude" }
        return candidates.first { fm.isExecutableFile(atPath: $0) }
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
