import Foundation

/// File locations under ~/.afkpug
enum Paths {
    /// In simulation everything lives in a sandbox so the real app never sees it.
    static let root = Sim.enabled
        ? Sim.dir.appendingPathComponent("root")
        : FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".afkpug")
    static let holds = root.appendingPathComponent("holds")
    static let events = root.appendingPathComponent("events")
    /// What each session is working on (`<hold id>`, `<hold id>.now`), written by the hook.
    static let tasks = root.appendingPathComponent("tasks")
    static let bin = root.appendingPathComponent("bin")
    static let state = root.appendingPathComponent("state")
    static let lidFlag = state.appendingPathComponent("lid-override")
    static let lowPowerFlag = state.appendingPathComponent("lowpower-restore")
    static let muteFlag = state.appendingPathComponent("mute-restore")
    /// "<pid>\n<executable path>\n" of the running menu bar app, for the watchdog
    /// and the CLI (a renamed or moved bundle still counts as running).
    static let appPid = state.appendingPathComponent("app.pid")
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

    static func writeAppPid() {
        ensure()
        let exe = Bundle.main.executablePath ?? CommandLine.arguments[0]
        try? "\(getpid())\n\(exe)\n".write(to: appPid, atomically: true, encoding: .utf8)
    }

    /// Only our own pid file: a second copy quitting must not unregister the first.
    static func removeAppPid() {
        guard let text = try? String(contentsOf: appPid, encoding: .utf8),
              text.split(separator: "\n").first.map(String.init) == String(getpid()) else { return }
        try? FileManager.default.removeItem(at: appPid)
    }
}

/// What a session is working on, from its hook events. Only ever shown on this Mac.
struct AgentTask: Equatable {
    var cwd: String?
    var prompt: String?
    var tool: String?
    var target: String?
    var waiting = false
    /// Which window it runs in, for going back to it.
    var place: AgentPlace? = nil

    /// The folder's name.
    var project: String? {
        guard let cwd, !cwd.isEmpty, cwd != "/" else { return nil }
        return URL(fileURLWithPath: cwd).lastPathComponent
    }

    /// The request on one line.
    var promptLine: String? {
        guard let prompt else { return nil }
        let line = prompt.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return line.isEmpty ? nil : String(line.prefix(200))
    }

    /// "AFK Pug · fix the flicker": which job this is.
    var title: String? {
        let parts = [project, promptLine].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The current step. A command shows its first two words only: the rest can hold secrets.
    var activity: String? {
        guard let tool else { return nil }
        let name = tool.split(separator: "_", omittingEmptySubsequences: true).count > 2 && tool.hasPrefix("mcp__")
            ? String(tool.components(separatedBy: "__").last ?? tool) : tool
        let file = target.map { URL(fileURLWithPath: $0).lastPathComponent }.flatMap { $0.isEmpty ? nil : $0 }
        switch name.lowercased() {
        case "edit", "multiedit", "write", "notebookedit", "replace", "write_file", "edit_file", "apply_patch":
            return file.map { tr("Editing %@", $0) } ?? tr("Editing files")
        case "read", "read_file", "read_many_files":
            return file.map { tr("Reading %@", $0) } ?? tr("Reading files")
        case "bash", "shell", "run_shell_command", "exec_command", "local_shell":
            let words = (target ?? "").split(whereSeparator: \.isWhitespace).prefix(2).joined(separator: " ")
            return words.isEmpty ? tr("Running a command") : tr("Running %@", words)
        case "grep", "glob", "ls", "search_file_content", "list_directory", "codebase_search":
            return tr("Searching the code")
        case "webfetch", "websearch", "web_fetch", "web_search", "google_web_search":
            return tr("Reading the web")
        case "task", "agent":
            return tr("Running a helper agent")
        case "todowrite", "write_todos", "update_plan":
            return tr("Planning")
        default:
            return tr("Using %@", name)
        }
    }
}

/// A turn that ended, for the "Just finished" list.
struct FinishedTask: Identifiable, Equatable {
    let id: UUID
    let agent: String
    let task: AgentTask?
    let at: Date
    let failed: Bool
}

/// One "keep me awake" claim from an agent, the CLI, or `afkpug run`.
struct AgentHold: Identifiable, Equatable {
    let id: String
    let agent: String
    let started: Date
    let expires: Date?
    let reason: String?
    var task: AgentTask? = nil

    /// The agent's name only ("Claude Code", "Codex", "Terminal hold"); the UI shows
    /// `reason` / `expires` separately.
    var displayName: String {
        agent.lowercased() == "cli" ? tr("Terminal hold") : AgentIntegrations.displayName(agent)
    }

    /// Name for the activity log: CLI holds are told apart by their reason.
    var logName: String {
        if agent.lowercased() == "cli", let reason { return tr("Hold · %@", reason) }
        return displayName
    }

    /// Written by afkpug-hook on a Claude usage limit (expires at the reset + 2 min).
    var isUsageLimitWait: Bool { reason == "usage limit" }

    /// A hold written by an agent's own hooks: id `<agent>-<session>`, agent is one of
    /// the integrations (not `cli-*`, `mcp-*`, `run-*` or a detected process).
    var isHookHold: Bool {
        let a = agent.lowercased()
        return id.hasPrefix(a + "-") && AgentIntegrations.integration(a) != nil
    }
}

/// Something an agent reported: finished a turn, or waiting for you.
struct AgentEvent {
    enum Kind: String { case done, waiting, failed }
    let kind: Kind
    let agent: String
    /// Session id from the file name (`...@<sid>`); nil for old-style names.
    var session: String? = nil
    /// The hold this event belongs to (`<agent>-<sid>`), if the session is known.
    var holdId: String? { session.map { "\(agent)-\($0)" } }
}

enum HoldStore {
    /// Holds without an expiry (Claude hooks, `afkpug run`) are re-armed by every
    /// tool call / every minute. Untouched this long, they are dropped unless the
    /// owner's process tree is still busy (a single 40 min build is one tool call).
    /// Covers turns that end without a Stop hook (Esc, some API errors).
    static let untouchedAfter: TimeInterval = 15 * 60
    /// A turn that ended with background work in flight ("bg":1) has nothing left to
    /// touch the hold: once the owner's tree goes quiet this long, the work is done
    /// (or it's an idle dev server) and the countdown starts.
    static let bgUntouchedAfter: TimeInterval = 3 * 60
    /// Hard cap for holds without an expiry, busy or not.
    static let staleAfter: TimeInterval = 6 * 3600
    /// No writer sets an expiry further than this ahead (CLI max 24 h, MCP 12 h,
    /// usage limit 6 h): anything beyond is corrupt and must not hold forever.
    static let maxExpiry: TimeInterval = 24 * 3600 + 60

    static func scan(now: Date = Date()) -> [AgentHold] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: Paths.holds, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        var result: [AgentHold] = []
        for url in files {
            let name = url.lastPathComponent
            if name.hasPrefix(".") {
                // Hook scratch files: end markers (60 s), claims and temp files left by a killed hook.
                if name.hasPrefix(".ended-") || name.hasPrefix(".claim-") || name.hasSuffix(".tmp"),
                   let m = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                   abs(Date().timeIntervalSince(m)) > 600 {
                    try? fm.removeItem(at: url)
                }
                continue
            }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? now
            // An unparseable file (e.g. a reason with control characters from an
            // old CLI) has no expiry and no owner, so it only lives `untouchedAfter`.
            let json = (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            let startedRaw = (json["started"] as? Double).flatMap { $0.isFinite ? $0 : nil }
            let started = startedRaw.map { Date(timeIntervalSince1970: $0) } ?? modified
            let expiresRaw = (json["expires"] as? Double).flatMap { $0.isFinite ? $0 : nil } ?? 0
            let expires = expiresRaw > 0 ? Date(timeIntervalSince1970: min(expiresRaw, 4e10)) : nil
            let pid = (json["pid"] as? NSNumber)?.int32Value ?? 0
            let quietAfter = (json["bg"] as? NSNumber)?.intValue == 1 ? bgUntouchedAfter : untouchedAfter

            var stale: Bool
            if let expires {
                // Years away or 1e300: corrupt, never a reason to stay awake.
                let tooFar = expiresRaw > now.timeIntervalSince1970 + maxExpiry
                    || startedRaw.map { expiresRaw > $0 + maxExpiry } == true
                stale = expires < now || tooFar
            } else {
                let untouched = now.timeIntervalSince(modified)
                stale = untouched > staleAfter || (untouched > quietAfter && !(pid > 1 && ProcessWatcher.treeBusy(pid)))
            }
            // Holds that name their owner die with it (a killed terminal never runs the Stop hook).
            if pid > 1, kill(pid, 0) != 0, errno == ESRCH { stale = true }
            if stale {
                try? fm.removeItem(at: url)
                continue
            }
            let reason = (json["reason"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            result.append(AgentHold(id: url.lastPathComponent, agent: json["agent"] as? String ?? "agent",
                                    started: started, expires: expires, reason: reason, task: readTask(url.lastPathComponent)))
        }
        cleanTasks(liveHolds: Set(result.map(\.id)), now: now)
        // Same second (hooks fired together): by id, so the order is stable.
        return result.sorted { $0.started != $1.started ? $0.started < $1.started : $0.id < $1.id }
    }

    static func release(_ hold: AgentHold) {
        try? FileManager.default.removeItem(at: Paths.holds.appendingPathComponent(hold.id))
        removeTask(hold.id)
    }

    static func readTask(_ id: String) -> AgentTask? {
        func object(_ name: String) -> [String: Any]? {
            (try? Data(contentsOf: Paths.tasks.appendingPathComponent(name)))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        }
        func text(_ value: Any?) -> String? { (value as? String).flatMap { $0.isEmpty ? nil : $0 } }
        let base = object(id), now = object(id + ".now")
        guard base != nil || now != nil else { return nil }
        return AgentTask(cwd: text(base?["cwd"]), prompt: text(base?["prompt"]), tool: text(now?["tool"]),
                         target: text(now?["target"]), waiting: now?["waiting"] != nil, place: base.flatMap(AgentPlace.init))
    }

    /// The task of a turn that ended; its files go away with it.
    static func takeTask(_ id: String) -> AgentTask? {
        defer { removeTask(id) }
        return readTask(id)
    }

    private static func removeTask(_ id: String) {
        try? FileManager.default.removeItem(at: Paths.tasks.appendingPathComponent(id))
        try? FileManager.default.removeItem(at: Paths.tasks.appendingPathComponent(id + ".now"))
    }

    /// Prompts shouldn't linger: a session that ended without being reported goes after an hour.
    private static func cleanTasks(liveHolds: Set<String>, now: Date) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: Paths.tasks, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for url in files {
            let name = url.lastPathComponent
            let id = name.hasSuffix(".now") ? String(name.dropLast(4)) : name
            guard !liveHolds.contains(id),
                  let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  abs(now.timeIntervalSince(modified)) > 3600 else { continue }
            try? fm.removeItem(at: url)
        }
    }

    /// Drops every hook hold of one agent (`holds/<agent>-*`), e.g. on disconnect.
    static func releaseAll(agent: String) {
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: Paths.holds.path)) ?? [] where name.hasPrefix(agent + "-") {
            try? fm.removeItem(at: Paths.holds.appendingPathComponent(name))
        }
    }

    /// Reads and deletes pending event files. Events written before `notBefore`
    /// (e.g. while the app wasn't running) are deleted without being reported.
    static func consumeEvents(notBefore: Date? = nil) -> [AgentEvent] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: Paths.events, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        var events: [AgentEvent] = []
        for url in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
            // name: <timestamp>-<agent>-<kind>[@<session>]  (older hooks: no session)
            let name = url.lastPathComponent
            let at = name.firstIndex(of: "@")
            let base = at.map { String(name[..<$0]) } ?? name
            let session = at.map { String(name[name.index(after: $0)...]) }.flatMap { $0.isEmpty ? nil : $0 }
            let parts = base.split(separator: "-")
            if !name.hasPrefix("."), notBefore.map({ modified >= $0 }) ?? true,
               parts.count >= 3, let kind = AgentEvent.Kind(rawValue: String(parts.last!)) {
                events.append(AgentEvent(kind: kind, agent: parts[1...(parts.count - 2)].joined(separator: "-"), session: session))
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

/// A settings file whose hooks look like Claude Code's:
/// `{"hooks": {"<Event>": [{"matcher": ..., "hooks": [{"type": "command", "command": ...}]}]}}`.
/// Claude Code and Gemini CLI both use this shape.
struct NestedHooksFile: Sendable {
    let url: URL
    let agent: String
    let events: [(event: String, action: String)]
    /// Extra keys for each hook entry (Gemini: name, timeout in ms).
    var extra: @Sendable (_ event: String) -> [String: Any] = { _ in [:] }

    func command(_ action: String) -> String { ConfigFile.hookCommand(action, agent) }

    func isInstalled() -> Bool { ConfigFile.hasOurHooks(url) }

    /// Connected, but by an older version (missing events or other commands).
    func needsUpgrade() -> Bool {
        guard isInstalled(), let settings = try? ConfigFile.loadJSON(url), let hooks = settings["hooks"] as? [String: Any] else { return false }
        let wanted = Set(events.map(\.event))
        let stray = hooks.contains { key, value in
            !wanted.contains(key) && ((value as? [[String: Any]]) ?? []).contains { !ours($0).isEmpty }
        }
        return stray || events.contains { event, action in
            let mine = (hooks[event] as? [[String: Any]] ?? []).flatMap(ours)
            return mine.count != 1 || mine[0] != command(action)
        }
    }

    func install() throws {
        var settings = try ConfigFile.loadJSON(url)
        var hooks = stripAll(try ConfigFile.hooksObject(settings, url))
        for (event, action) in events {
            var groups = hooks[event] as? [[String: Any]] ?? []
            var entry: [String: Any] = ["type": "command", "command": command(action)]
            entry.merge(extra(event)) { $1 }
            groups.append(["hooks": [entry]])
            hooks[event] = groups
        }
        settings["hooks"] = hooks
        try ConfigFile.saveJSON(settings, to: url)
    }

    func uninstall() throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        var settings = try ConfigFile.loadJSON(url)
        guard settings["hooks"] != nil else { return }
        let stripped = stripAll(try ConfigFile.hooksObject(settings, url))
        settings["hooks"] = stripped.isEmpty ? nil : stripped
        try ConfigFile.saveJSON(settings, to: url)
    }

    /// Our commands in one matcher group.
    private func ours(_ group: [String: Any]) -> [String] {
        (group["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String }.filter { $0.contains(ConfigFile.marker) }
    }

    /// Removes our entries from every event (also ones an older version used),
    /// dropping groups and events left empty. Non-array values are kept as is.
    private func stripAll(_ hooks: [String: Any]) -> [String: Any] {
        var result = hooks
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else { continue }
            let kept: [[String: Any]] = groups.compactMap { group in
                guard let inner = group["hooks"] as? [[String: Any]] else { return group }
                let left = inner.filter { !(($0["command"] as? String) ?? "").contains(ConfigFile.marker) }
                if left.count == inner.count { return group }
                if left.isEmpty { return nil }
                var group = group
                group["hooks"] = left
                return group
            }
            result[event] = kept.isEmpty ? nil : kept
        }
        return result
    }
}

/// Adds / removes AFK Pug hooks in ~/.claude/settings.json, unless the AFK Pug
/// Claude Code plugin (plugin/ in the repo) already provides them.
enum ClaudeHooks {
    static let settingsURL = ConfigFile.home(".claude/settings.json")
    static let pluginsURL = ConfigFile.home(".claude/plugins/installed_plugins.json")
    /// The plugin's name in plugin/.claude-plugin/plugin.json and marketplace.json.
    static let pluginName = "afk-pug"
    static let marker = ConfigFile.marker
    static let events: [(event: String, action: String)] = [
        ("UserPromptSubmit", "start"),
        ("PreToolUse", "touch"),
        ("PostToolUse", "touch"),
        ("Stop", "stop"),
        ("Notification", "notify"),
        ("StopFailure", "fail"),
        ("SessionEnd", "end"),
    ]
    static let file = NestedHooksFile(url: settingsURL, agent: "claude", events: events)

    static func isInstalled() -> Bool { file.isInstalled() }
    static func needsUpgrade() -> Bool { file.needsUpgrade() }
    /// Hooks in settings.json while the plugin also provides them: every event would
    /// fire twice, so they have to go (boot / refresh calls `install()`, which removes them).
    static func doubledByPlugin() -> Bool { isInstalled() && pluginInstalled() }

    /// With the plugin installed, settings.json hooks would fire every event twice.
    static func install() throws {
        if pluginInstalled() { try file.uninstall() } else { try file.install() }
    }

    static func uninstall() throws { try file.uninstall() }

    /// The AFK Pug plugin is installed at user scope (from any marketplace) and
    /// not turned off in ~/.claude/settings.json `enabledPlugins`.
    static func pluginInstalled() -> Bool {
        guard let data = try? ConfigFile.read(pluginsURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let plugins = json["plugins"] as? [String: Any] else { return false }
        let enabled = ((try? ConfigFile.loadJSON(settingsURL))?["enabledPlugins"] as? [String: Any]) ?? [:]
        return plugins.contains { id, installs in
            guard id.split(separator: "@").first.map(String.init) == pluginName,
                  ((installs as? [[String: Any]]) ?? []).contains(where: { ($0["scope"] as? String) == "user" }) else { return false }
            return (enabled[id] as? Bool) != false
        }
    }
}

/// Removes everything AFK Pug added to this Mac, with one admin prompt for the
/// root-owned part. Blocking: call it off the main thread.
enum Uninstaller {
    struct Report { var errors: [String] = [] }

    static func run() -> Report {
        var report = Report()
        // Every config, connected or not (an old or hand-edited entry may not be detected);
        // a file we can't parse only counts as a problem if it holds our hook.
        do { try ClaudeHooks.uninstall() } catch {
            if ConfigFile.mentionsHook(ClaudeHooks.settingsURL) { report.errors.append("Claude Code hooks: \(error.localizedDescription)") }
        }
        for (item, url) in [(AgentIntegrations.codex, CodexHooks.file.url), (AgentIntegrations.gemini, GeminiHooks.file.url),
                            (AgentIntegrations.cursor, CursorHooks.configURL)] {
            do { try item.disconnect() } catch {
                if ConfigFile.mentionsHook(url) { report.errors.append("\(item.name) hooks: \(error.localizedDescription)") }
            }
        }
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
