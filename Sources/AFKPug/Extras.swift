import Foundation
import AppKit
import Carbon.HIToolbox
import CoreAudio

// MARK: - Agents without hooks (Codex, Gemini CLI, Cursor Agent, ...)

/// Detects CLI agents by process and counts them as working while their
/// process tree uses CPU.
enum ProcessWatcher {
    static let known: [(key: String, display: String)] = [
        ("codex", "Codex"),
        ("gemini", "Gemini CLI"),
        ("cursor-agent", "Cursor Agent"),
        ("aider", "Aider"),
        ("opencode", "OpenCode"),
        ("amp", "Amp"),
        ("goose", "Goose"),
        ("qwen", "Qwen Code"),
    ]
    /// Process tree CPU % above which the agent counts as busy.
    static let busyCPU = 3.0

    struct Busy { let pid: Int32; let display: String; let cpu: Double }

    static func scan() -> [Busy] {
        let out = PowerControl.run("/bin/ps", ["-Ao", "pid=,ppid=,pcpu=,args="]).output
        var cpu: [Int32: Double] = [:]
        var children: [Int32: [Int32]] = [:]
        var agents: [(Int32, String)] = []

        for line in out.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard parts.count == 4, let pid = Int32(parts[0]), let ppid = Int32(parts[1]), let pc = Double(parts[2]) else { continue }
            cpu[pid] = pc
            children[ppid, default: []].append(pid)
            // Match the executable or the script node runs (first 3 args).
            let names = parts[3].split(separator: " ").prefix(3).map { String($0.split(separator: "/").last ?? "") }
            if let match = known.first(where: { names.contains($0.key) }) {
                agents.append((pid, match.display))
            }
        }

        // Skip agents nested inside another matched agent (e.g. node -> codex).
        let agentPids = Set(agents.map(\.0))
        var nested = Set<Int32>()
        for (pid, _) in agents {
            var stack = children[pid] ?? []
            while let c = stack.popLast() {
                if agentPids.contains(c) { nested.insert(c) }
                stack.append(contentsOf: children[c] ?? [])
            }
        }

        return agents.filter { !nested.contains($0.0) }.compactMap { pid, display in
            var total = 0.0
            var stack = [pid]
            while let p = stack.popLast() {
                total += cpu[p] ?? 0
                stack.append(contentsOf: children[p] ?? [])
            }
            return total >= busyCPU ? Busy(pid: pid, display: display, cpu: total) : nil
        }
    }
}

// MARK: - Pause chat apps while the lid is closed

enum ChatPauser {
    static let apps = ["Slack", "Discord", "WhatsApp", "Telegram", "LINE", "Messenger", "Microsoft Teams"]
    static let file = Paths.state.appendingPathComponent("paused-pids")

    static func pause() {
        var pids: [Int32] = []
        for app in apps {
            let out = PowerControl.run("/usr/bin/pgrep", ["-f", "/Applications/\(app).app/"]).output
            pids += out.split(separator: "\n").compactMap { Int32($0) }
        }
        guard !pids.isEmpty else { return }
        Paths.ensure()
        try? pids.map(String.init).joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
        for pid in pids { kill(pid, SIGSTOP) }
    }

    static func resume() {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return }
        for pid in text.split(separator: "\n").compactMap({ Int32($0) }) { kill(pid, SIGCONT) }
        try? FileManager.default.removeItem(at: file)
    }
}

// MARK: - Lock the screen

enum ScreenLock {
    /// Locks immediately, like ⌃⌘Q.
    static func lock() {
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
            let minutes = max(1, min(720, (args["minutes"] as? Int) ?? Int(args["minutes"] as? Double ?? 30)))
            let reason = (args["reason"] as? String ?? "agent").replacingOccurrences(of: "\"", with: "")
            let now = Date().timeIntervalSince1970
            let id = "mcp-\(Int(now))-\(Int.random(in: 1000...9999))"
            let json: [String: Any] = ["agent": "cli", "started": now, "expires": now + Double(minutes * 60), "reason": reason]
            if let data = try? JSONSerialization.data(withJSONObject: json) {
                try? data.write(to: Paths.holds.appendingPathComponent(id))
            }
            let running = PowerControl.run("/usr/bin/pgrep", ["-x", "AFKPug"]).status == 0
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

/// Registers the MCP server with Claude Code (user scope).
enum MCPInstaller {
    static var executable: String { Bundle.main.executablePath ?? CommandLine.arguments[0] }

    static func isInstalled() -> Bool {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
        return text.contains("\"afkpug\"")
    }

    @discardableResult
    static func install() -> Bool {
        let cmd = "claude mcp remove --scope user afkpug >/dev/null 2>&1; claude mcp add --scope user afkpug -- '\(executable)' --mcp"
        return PowerControl.run("/bin/zsh", ["-lc", cmd]).status == 0
    }

    static func uninstall() {
        PowerControl.run("/bin/zsh", ["-lc", "claude mcp remove --scope user afkpug"])
    }
}

// MARK: - Is audio playing?

enum AudioWatcher {
    /// True when any app is sending audio to the default output (music, YouTube, a call).
    static func isPlaying() -> Bool {
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
