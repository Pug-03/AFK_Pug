import Foundation

/// File locations under ~/.afkpug
enum Paths {
    /// In simulation everything lives in a sandbox so the real app never sees it.
    static let root = Sim.enabled
        ? Sim.dir.appendingPathComponent("root")
        : FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".afkpug")
    static let holds = root.appendingPathComponent("holds")
    static let events = root.appendingPathComponent("events")
    static let bin = root.appendingPathComponent("bin")
    static let state = root.appendingPathComponent("state")
    static let lidFlag = state.appendingPathComponent("lid-override")
    static let lowPowerFlag = state.appendingPathComponent("lowpower-restore")
    static let muteFlag = state.appendingPathComponent("mute-restore")
    static let hookScript = bin.appendingPathComponent("afkpug-hook")
    static let cliScript = bin.appendingPathComponent("afkpug")
    static let watchdogScript = bin.appendingPathComponent("watchdog.sh")
    static let watchdogPlist = Sim.enabled
        ? root.appendingPathComponent("com.pug03.afkpug.watchdog.plist")
        : FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/com.pug03.afkpug.watchdog.plist")

    static func ensure() {
        for dir in [root, holds, events, bin, state] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    static func touch(_ url: URL) {
        ensure()
        FileManager.default.createFile(atPath: url.path, contents: Data())
    }
}

/// One "keep me awake" claim from an agent, the CLI, or `afkpug run`.
struct AgentHold: Identifiable, Equatable {
    let id: String
    let agent: String
    let started: Date
    let expires: Date?
    let reason: String?

    var displayName: String {
        switch agent.lowercased() {
        case "claude": return "Claude Code"
        case "codex": return "Codex"
        case "cli": return reason.map { tr("Hold · %@", $0) } ?? tr("Terminal hold")
        default: return agent
        }
    }
}

/// Something an agent reported: finished a turn, or waiting for you.
struct AgentEvent {
    enum Kind: String { case done, waiting, failed }
    let kind: Kind
    let agent: String
}

enum HoldStore {
    /// Holds without an expiry (Claude hooks, `afkpug run`) are re-armed by every
    /// tool call / every minute. Untouched this long, they are dropped unless the
    /// owner's process tree is still busy (a single 40 min build is one tool call).
    /// Covers turns that end without a Stop hook (Esc, some API errors).
    static let untouchedAfter: TimeInterval = 15 * 60
    /// Hard cap for holds without an expiry, busy or not.
    static let staleAfter: TimeInterval = 6 * 3600

    static func scan(now: Date = Date()) -> [AgentHold] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: Paths.holds, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        var result: [AgentHold] = []
        for url in files where !url.lastPathComponent.hasPrefix(".") {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? now
            // An unparseable file (e.g. a reason with control characters from an
            // old CLI) has no expiry and no owner, so it only lives `untouchedAfter`.
            let json = (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            let started = (json["started"] as? Double).map { Date(timeIntervalSince1970: $0) } ?? modified
            let expiresRaw = json["expires"] as? Double ?? 0
            let expires = expiresRaw > 0 ? Date(timeIntervalSince1970: expiresRaw) : nil
            let pid = (json["pid"] as? NSNumber)?.int32Value ?? 0

            var stale: Bool
            if let expires {
                stale = expires < now
            } else {
                let untouched = now.timeIntervalSince(modified)
                stale = untouched > staleAfter || (untouched > untouchedAfter && !(pid > 1 && ProcessWatcher.treeBusy(pid)))
            }
            // Holds that name their owner die with it (a killed terminal never runs the Stop hook).
            if pid > 1, kill(pid, 0) != 0, errno == ESRCH { stale = true }
            if stale {
                try? fm.removeItem(at: url)
                continue
            }
            let reason = (json["reason"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            result.append(AgentHold(id: url.lastPathComponent, agent: json["agent"] as? String ?? "agent",
                                    started: started, expires: expires, reason: reason))
        }
        return result.sorted { $0.started < $1.started }
    }

    static func release(_ hold: AgentHold) {
        try? FileManager.default.removeItem(at: Paths.holds.appendingPathComponent(hold.id))
    }

    /// Reads and deletes pending event files. Events written before `notBefore`
    /// (e.g. while the app wasn't running) are deleted without being reported.
    static func consumeEvents(notBefore: Date? = nil) -> [AgentEvent] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: Paths.events, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        var events: [AgentEvent] = []
        for url in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
            // name: <timestamp>-<agent>-<kind>
            let parts = url.lastPathComponent.split(separator: "-")
            if notBefore.map({ modified >= $0 }) ?? true,
               parts.count >= 3, let kind = AgentEvent.Kind(rawValue: String(parts.last!)) {
                events.append(AgentEvent(kind: kind, agent: parts[1...(parts.count - 2)].joined(separator: "-")))
            }
            try? fm.removeItem(at: url)
        }
        return events
    }
}

/// Writes the helper scripts and the crash watchdog.
enum Installer {
    static func installScripts() {
        Paths.ensure()
        write(Scripts.hook, to: Paths.hookScript)
        write(Scripts.cli, to: Paths.cliScript)
        write(Scripts.watchdog, to: Paths.watchdogScript)
    }

    /// LaunchAgent that restores normal lid sleep if AFK Pug dies while the override is on.
    static func installWatchdog() {
        if Sim.enabled { Sim.record("install watchdog LaunchAgent (skipped)"); return }
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
          <key>Label</key><string>com.pug03.afkpug.watchdog</string>
          <key>ProgramArguments</key><array><string>/bin/sh</string><string>\(Paths.watchdogScript.path)</string></array>
          <key>StartInterval</key><integer>30</integer>
          <key>RunAtLoad</key><true/>
        </dict></plist>
        """
        let existing = try? String(contentsOf: Paths.watchdogPlist, encoding: .utf8)
        guard existing != plist else { return }
        try? FileManager.default.createDirectory(at: Paths.watchdogPlist.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? plist.write(to: Paths.watchdogPlist, atomically: true, encoding: .utf8)
        let domain = "gui/\(getuid())"
        PowerControl.run("/bin/launchctl", ["bootout", domain, Paths.watchdogPlist.path])
        PowerControl.run("/bin/launchctl", ["bootstrap", domain, Paths.watchdogPlist.path])
    }

    private static func write(_ text: String, to url: URL) {
        try? text.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}

/// Adds / removes AFK Pug hooks in ~/.claude/settings.json.
enum ClaudeHooks {
    static let settingsURL = (Sim.enabled ? Paths.root : FileManager.default.homeDirectoryForCurrentUser)
        .appendingPathComponent(".claude/settings.json")
    /// Only our own commands carry this path tail.
    static let marker = "/bin/afkpug-hook"
    static let events: [(event: String, action: String)] = [
        ("UserPromptSubmit", "start"),
        ("PreToolUse", "touch"),
        ("PostToolUse", "touch"),
        ("Stop", "stop"),
        ("Notification", "notify"),
        ("StopFailure", "fail"),
        ("SessionEnd", "end"),
    ]

    static func isInstalled() -> Bool {
        guard let data = try? Data(contentsOf: settingsURL), let text = String(data: data, encoding: .utf8) else { return false }
        return text.contains(marker)
    }

    /// Connected, but by an older version (missing events or other commands).
    static func needsUpgrade() -> Bool {
        guard isInstalled(), let settings = try? load(), let hooks = settings["hooks"] as? [String: Any] else { return false }
        return events.contains { event, action in
            let commands = (hooks[event] as? [[String: Any]] ?? []).flatMap { $0["hooks"] as? [[String: Any]] ?? [] }
                .compactMap { $0["command"] as? String }
            return !commands.contains(command(action))
        }
    }

    /// Fail-safe: if the app (and its script) is gone, the hook does nothing instead of
    /// showing a hook error on every prompt. Single quotes so `$` in a path can't expand.
    private static func command(_ action: String) -> String {
        let path = "'" + Paths.hookScript.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return "[ -x \(path) ] && \(path) \(action) claude; true"
    }

    static func install() throws {
        var settings = try load()
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        for (event, action) in events {
            var groups = stripOurs(hooks[event] as? [[String: Any]] ?? [])
            groups.append(["hooks": [["type": "command", "command": command(action)]]])
            hooks[event] = groups
        }
        settings["hooks"] = hooks
        try save(settings)
    }

    static func uninstall() throws {
        var settings = try load()
        guard var hooks = settings["hooks"] as? [String: Any] else { return }
        for (event, _) in events {
            let groups = stripOurs(hooks[event] as? [[String: Any]] ?? [])
            hooks[event] = groups.isEmpty ? nil : groups
        }
        settings["hooks"] = hooks.isEmpty ? nil : hooks
        try save(settings)
    }

    private static func stripOurs(_ groups: [[String: Any]]) -> [[String: Any]] {
        groups.compactMap { group in
            var group = group
            let inner = (group["hooks"] as? [[String: Any]] ?? []).filter { !(($0["command"] as? String) ?? "").contains(marker) }
            if inner.isEmpty { return nil }
            group["hooks"] = inner
            return group
        }
    }

    private static func load() throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return [:] }
        let data = try Data(contentsOf: settingsURL)
        if data.isEmpty { return [:] }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "AFKPug", code: 2, userInfo: [NSLocalizedDescriptionKey: "~/.claude/settings.json is not a JSON object"])
        }
        return object
    }

    private static func save(_ settings: [String: Any]) throws {
        let fm = FileManager.default
        // settings.json is often a symlink into a dotfiles repo: write through it
        // (an atomic write to the link path would replace the link with a file).
        var target = settingsURL.resolvingSymlinksInPath()
        // A dangling link: write to where it points, keeping the link.
        if let dest = try? fm.destinationOfSymbolicLink(atPath: settingsURL.path), !fm.fileExists(atPath: target.path) {
            target = URL(fileURLWithPath: dest, relativeTo: settingsURL.deletingLastPathComponent()).standardizedFileURL
        }
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: target.path) {
            guard fm.isWritableFile(atPath: target.path) else {
                throw NSError(domain: "AFKPug", code: 3, userInfo: [NSLocalizedDescriptionKey: "~/.claude/settings.json is read-only"])
            }
            // Keep the very first backup: it is the user's original file.
            let backup = settingsURL.appendingPathExtension("afkpug-backup")
            if !fm.fileExists(atPath: backup.path) { try? fm.copyItem(at: target, to: backup) }
        }
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: target, options: .atomic)
    }
}

/// Removes everything AFK Pug added to this Mac, with one admin prompt for the
/// root-owned part. Blocking: call it off the main thread.
enum Uninstaller {
    struct Report { var errors: [String] = [] }

    static func run() -> Report {
        var report = Report()
        do { try ClaudeHooks.uninstall() } catch { report.errors.append("Claude Code hooks: \(error.localizedDescription)") }
        if MCPInstaller.isInstalled(), !MCPInstaller.uninstall() { report.errors.append("Claude Code MCP server: run `claude mcp remove --scope user afkpug`") }
        if Sim.enabled {
            Sim.record("uninstall: launchctl bootout watchdog, remove plist, sudoers, ~/.afkpug")
        } else {
            PowerControl.run("/bin/launchctl", ["bootout", "gui/\(getuid())", Paths.watchdogPlist.path])
            try? FileManager.default.removeItem(at: Paths.watchdogPlist)
            if FileManager.default.fileExists(atPath: PowerControl.sudoersPath) || PowerControl.sleepDisabled() {
                let shell = "/usr/bin/pmset -a disablesleep 0; /bin/rm -f \(PowerControl.sudoersPath) /etc/sudoers.d/.afkpug.new"
                if case .failure(let error) = PowerControl.runAsAdmin(shell, prompt: "AFK Pug will remove its permission and restore normal sleep.") {
                    report.errors.append(error == .cancelled ? "Permission not removed (cancelled)" : "Permission: \(error.message)")
                }
            }
            try? LoginItem.set(false)
        }
        try? FileManager.default.removeItem(at: Paths.root)
        return report
    }
}
