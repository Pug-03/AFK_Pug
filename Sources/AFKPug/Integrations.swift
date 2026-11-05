import Foundation

/// One coding agent AFK Pug connects to through that agent's own hook system.
/// The UI lists `AgentIntegrations.all`; the engine connects / disconnects by id.
struct AgentIntegration: Identifiable, Sendable {
    /// Also the agent name used in hold files and events ("claude", "codex", ...).
    let id: String
    let name: String
    /// Config file AFK Pug edits, shown in the UI (e.g. "~/.claude/settings.json").
    let configPath: String
    /// The agent seems installed on this Mac (cheap check: no shells spawned).
    let isAvailable: @Sendable () -> Bool
    let isConnected: @Sendable () -> Bool
    /// Connected by an older AFK Pug version; reconnecting upgrades it.
    let needsUpgrade: @Sendable () -> Bool
    let connect: @Sendable () throws -> Void
    let disconnect: @Sendable () throws -> Void
    /// ProcessWatcher display names this integration replaces while connected
    /// (the native hooks hold the Mac awake, so process detection would double it).
    var processNames: [String] = []
    /// English text of a step the user still has to take in the agent itself after
    /// connecting; translated on every read so it follows the current language.
    var setupNoteKey: String? = nil
    var setupNote: String? { setupNoteKey.map { tr($0) } }
}

enum AgentIntegrations {
    static var all: [AgentIntegration] { [claude, codex, gemini, cursor] }

    static func integration(_ id: String) -> AgentIntegration? { all.first { $0.id == id } }

    /// Human name for an agent id from a hold or event file ("claude" -> "Claude Code").
    static func displayName(_ agent: String) -> String {
        all.first { $0.id == agent.lowercased() }?.name ?? agent
    }

    /// Process detection names to skip right now: agents with a live hook hold
    /// (`<agent>-<session>`). Codex skips new hooks until the user trusts them in
    /// /hooks; until a hook really runs, process detection keeps covering it. A
    /// `cursor-*` hold counts even when only Claude Code's hooks are connected
    /// (Cursor runs those too).
    static func hookedProcessNames(holds: [AgentHold]) -> Set<String> {
        let live = Set(holds.filter(\.isHookHold).map { $0.agent.lowercased() })
        return Set(all.filter { live.contains($0.id) }.flatMap(\.processNames))
    }

    /// Hooks that can report this integration's agent: its own, or for Cursor also Claude Code's.
    static func hooksActive(_ item: AgentIntegration, connected: [String: Bool]) -> Bool {
        connected[item.id] == true || (item.id == "cursor" && connected["claude"] == true)
    }

    static let claude = AgentIntegration(
        id: "claude",
        name: "Claude Code",
        configPath: "~/.claude/settings.json",
        isAvailable: {
            FileManager.default.fileExists(atPath: ClaudeHooks.settingsURL.deletingLastPathComponent().path)
        },
        isConnected: { ClaudeHooks.isInstalled() || ClaudeHooks.pluginInstalled() },
        // With the plugin, settings.json hooks would double every event: "upgrading"
        // (install()) removes them.
        needsUpgrade: { ClaudeHooks.pluginInstalled() ? ClaudeHooks.isInstalled() : ClaudeHooks.needsUpgrade() },
        connect: { try ClaudeHooks.install() },
        disconnect: {
            try ClaudeHooks.uninstall()
            if ClaudeHooks.pluginInstalled() {
                throw ConfigFile.error(tr("AFK Pug is installed as a Claude Code plugin. Remove it in Claude Code with /plugin uninstall afk-pug."))
            }
        }
    )

    static let codex = AgentIntegration(
        id: "codex",
        name: "Codex",
        configPath: "~/.codex/hooks.json",
        isAvailable: { FileManager.default.fileExists(atPath: CodexHooks.file.url.deletingLastPathComponent().path) },
        isConnected: { CodexHooks.file.isInstalled() },
        needsUpgrade: { CodexHooks.file.needsUpgrade() },
        connect: { try CodexHooks.file.install() },
        disconnect: { try CodexHooks.file.uninstall() },
        processNames: ["Codex"],
        setupNoteKey: "Codex runs new hooks only after you trust them: open Codex and type /hooks."
    )

    static let gemini = AgentIntegration(
        id: "gemini",
        name: "Gemini CLI",
        configPath: "~/.gemini/settings.json",
        isAvailable: { FileManager.default.fileExists(atPath: GeminiHooks.file.url.deletingLastPathComponent().path) },
        isConnected: { GeminiHooks.file.isInstalled() },
        needsUpgrade: { GeminiHooks.file.needsUpgrade() },
        connect: { try GeminiHooks.file.install() },
        disconnect: { try GeminiHooks.file.uninstall() },
        processNames: ["Gemini CLI"]
    )

    static let cursor = AgentIntegration(
        id: "cursor",
        name: "Cursor",
        configPath: "~/.cursor/hooks.json",
        isAvailable: { FileManager.default.fileExists(atPath: CursorHooks.configURL.deletingLastPathComponent().path) },
        isConnected: { CursorHooks.isInstalled() },
        needsUpgrade: { CursorHooks.needsUpgrade() },
        connect: { try CursorHooks.install() },
        disconnect: { try CursorHooks.uninstall() },
        processNames: ["Cursor Agent"]
    )
}

// MARK: - Config file editing shared by every integration

/// Reads and writes an agent's config file the careful way: writes through
/// symlinks (dotfiles repos), keeps the user's very first version as
/// `<file>.afkpug-backup`, and refuses read-only files instead of replacing them.
enum ConfigFile {
    /// The user's home, or the simulator's fake one (separate from the fake ~/.afkpug,
    /// so uninstall can be checked to keep the user's other config).
    static var homeDir: URL { Sim.enabled ? Sim.home : FileManager.default.homeDirectoryForCurrentUser }

    /// `~/<relative>`, or in the simulator's fake home.
    static func home(_ relative: String) -> URL { homeDir.appendingPathComponent(relative) }

    static func error(_ message: String) -> NSError {
        NSError(domain: "AFKPug", code: 3, userInfo: [NSLocalizedDescriptionKey: message])
    }

    /// "~/.codex/config.toml" for messages.
    static func display(_ url: URL) -> String {
        let home = homeDir.path
        return url.path.hasPrefix(home + "/") ? "~" + url.path.dropFirst(home.count) : url.path
    }

    /// File contents, or nil if it doesn't exist (a dangling symlink counts as missing).
    static func read(_ url: URL) throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    static func write(_ data: Data, to url: URL) throws {
        let fm = FileManager.default
        // An atomic write to the link path would replace the link with a file.
        var target = url.resolvingSymlinksInPath()
        // A dangling link: write to where it points, keeping the link.
        if let dest = try? fm.destinationOfSymbolicLink(atPath: url.path), !fm.fileExists(atPath: target.path) {
            target = URL(fileURLWithPath: dest, relativeTo: url.deletingLastPathComponent()).standardizedFileURL
        }
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: target.path) {
            guard fm.isWritableFile(atPath: target.path) else {
                throw error(tr("%@ is read-only", display(url)))
            }
            if (try? Data(contentsOf: target)) == data { return }
            // Keep the very first backup: it is the user's original file.
            let backup = url.appendingPathExtension("afkpug-backup")
            if !fm.fileExists(atPath: backup.path) { try? fm.copyItem(at: target, to: backup) }
        }
        try data.write(to: target, options: .atomic)
    }

    /// A JSON object file ([:] when missing or empty).
    static func loadJSON(_ url: URL) throws -> [String: Any] {
        guard let data = try read(url), !data.isEmpty else { return [:] }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw error(tr("%@ is not a JSON object", display(url)))
        }
        return object
    }

    /// The `"hooks"` object ([:] when absent). Any other value is refused like
    /// malformed JSON instead of being silently replaced.
    static func hooksObject(_ json: [String: Any], _ url: URL) throws -> [String: Any] {
        guard let value = json["hooks"] else { return [:] }
        guard let hooks = value as? [String: Any] else {
            throw error(tr("%@ has a \"hooks\" value that is not an object", display(url)))
        }
        return hooks
    }

    /// Every hook command in a config file, parsed (so `\/` escapes don't matter):
    /// Claude Code / Codex / Gemini groups (`{"hooks": [{"command"}]}`) and Cursor
    /// entries (`{"command"}`). nil when the file can't be parsed.
    static func hookCommands(_ url: URL) -> [String]? {
        guard let json = try? loadJSON(url) else { return nil }
        guard let hooks = json["hooks"] as? [String: Any] else { return [] }
        return hooks.values.flatMap { value -> [String] in
            ((value as? [[String: Any]]) ?? []).flatMap { entry -> [String] in
                let inner = (entry["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String }
                return inner + [entry["command"] as? String].compactMap { $0 }
            }
        }
    }

    /// One of our hook commands is configured in `url`.
    static func hasOurHooks(_ url: URL) -> Bool {
        guard let commands = hookCommands(url) else { return mentionsHook(url) }
        return commands.contains { $0.contains(marker) }
    }

    /// Raw text check for files that don't parse (e.g. JSON with comments), also
    /// matching JSON-escaped slashes.
    static func mentionsHook(_ url: URL) -> Bool {
        guard let data = try? read(url), let text = String(data: data, encoding: .utf8) else { return false }
        return text.contains(marker) || text.contains(#"\/bin\/afkpug-hook"#)
    }

    static func saveJSON(_ object: [String: Any], to url: URL) throws {
        var data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        data.append(0x0A)
        try write(data, to: url)
    }

    /// The fail-safe hook command: does nothing (and succeeds) when the app and
    /// its script are gone. Single quotes so `$` in a path can't expand.
    static func hookCommand(_ action: String, _ agent: String) -> String {
        let path = shellQuote(Paths.hookScript.path)
        return "[ -x \(path) ] && \(path) \(action) \(agent); true"
    }

    static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// Only our own commands carry this path tail.
    static let marker = "/bin/afkpug-hook"
}

// MARK: - Codex

/// ~/.codex/hooks.json (Codex 0.124+; same shape as Claude Code's, timeouts in s).
/// JSON instead of inline `[hooks]` tables in config.toml, so no TOML is edited,
/// and the single `notify` program (turn end only) stays the user's.
/// Exit 0 with no output means "continue unchanged". Codex skips new hooks until
/// the user trusts them in /hooks. https://learn.chatgpt.com/docs/hooks
enum CodexHooks {
    static let events: [(event: String, action: String)] = [
        ("UserPromptSubmit", "start"),
        ("PreToolUse", "touch"),
        ("PostToolUse", "touch"),
        ("PermissionRequest", "wait"),
        ("Stop", "stop"),
        ("Interrupt", "end"),         // Esc: no "finished"
        ("SessionEnd", "end"),
    ]
    static let file = NestedHooksFile(url: ConfigFile.home(".codex/hooks.json"), agent: "codex", events: events) { event in
        // SessionEnd and Interrupt allow at most 3 s.
        ["timeout": event == "SessionEnd" || event == "Interrupt" ? 3 : 10]
    }
}

// MARK: - Gemini CLI

/// ~/.gemini/settings.json `hooks` (same shape as Claude Code's; timeouts in ms).
/// Empty stdout + exit 0 means "allow, no change", so the hook prints nothing.
/// https://github.com/google-gemini/gemini-cli/blob/main/docs/hooks/reference.md
enum GeminiHooks {
    static let events: [(event: String, action: String)] = [
        ("BeforeAgent", "start"),     // once per prompt
        ("BeforeTool", "touch"),
        ("AfterTool", "touch"),
        ("AfterAgent", "stop"),       // once per turn end (also after a caught API error)
        ("Notification", "wait"),     // ToolPermission
        ("SessionEnd", "end"),
    ]
    static let file = NestedHooksFile(url: ConfigFile.home(".gemini/settings.json"), agent: "gemini", events: events) { event in
        ["name": "afkpug-" + event.lowercased(), "timeout": 5000]
    }
}

// MARK: - Cursor

/// ~/.cursor/hooks.json: `{"version": 1, "hooks": {"<event>": [{"command": ...}]}}`.
/// Used by the Cursor app's agent and the cursor-agent CLI.
/// https://cursor.com/docs/agent/hooks
///
/// Only observational events: permission hooks (preToolUse, beforeShellExecution,
/// ...) would have to answer "allow", which could change what the user approves.
/// Every hook prints a valid, no-op JSON reply (Cursor blocks on invalid JSON).
enum CursorHooks {
    static let configURL = ConfigFile.home(".cursor/hooks.json")
    static let events: [(event: String, action: String)] = [
        ("beforeSubmitPrompt", "start"),
        ("postToolUse", "touch"),
        ("postToolUseFailure", "touch"),
        ("afterShellExecution", "touch"),
        ("afterFileEdit", "touch"),
        ("afterMCPExecution", "touch"),
        ("afterAgentThought", "touch"),
        ("stop", "stop"),             // status completed | aborted | error, handled by the script
        ("sessionEnd", "end"),
    ]

    /// beforeSubmitPrompt must say `continue`; the rest get an empty object.
    static func command(_ event: String, _ action: String) -> String {
        let reply = event == "beforeSubmitPrompt" ? #"{"continue":true}"# : "{}"
        let path = ConfigFile.shellQuote(Paths.hookScript.path)
        return "[ -x \(path) ] && \(path) \(action) cursor >/dev/null 2>&1; printf '%s\\n' '\(reply)'"
    }

    static func isInstalled() -> Bool { ConfigFile.hasOurHooks(configURL) }

    static func needsUpgrade() -> Bool {
        guard isInstalled(), let json = try? ConfigFile.loadJSON(configURL), let hooks = json["hooks"] as? [String: Any] else { return false }
        let wanted = Set(events.map(\.event))
        if hooks.contains(where: { key, value in !wanted.contains(key) && !ours(value).isEmpty }) { return true }
        return events.contains { event, action in ours(hooks[event]) != [command(event, action)] }
    }

    static func install() throws {
        var json = try ConfigFile.loadJSON(configURL)
        var hooks = strip(try ConfigFile.hooksObject(json, configURL))
        for (event, action) in events {
            var list = hooks[event] as? [[String: Any]] ?? []
            list.append(["command": command(event, action), "timeout": 10])
            hooks[event] = list
        }
        json["hooks"] = hooks
        if json["version"] == nil { json["version"] = 1 }
        try ConfigFile.saveJSON(json, to: configURL)
    }

    static func uninstall() throws {
        guard FileManager.default.fileExists(atPath: configURL.path) else { return }
        var json = try ConfigFile.loadJSON(configURL)
        guard json["hooks"] != nil else { return }
        json["hooks"] = strip(try ConfigFile.hooksObject(json, configURL))   // keep "hooks": {} and "version": a valid file
        try ConfigFile.saveJSON(json, to: configURL)
    }

    private static func ours(_ value: Any?) -> [String] {
        ((value as? [[String: Any]]) ?? []).compactMap { $0["command"] as? String }.filter { $0.contains(ConfigFile.marker) }
    }

    private static func strip(_ hooks: [String: Any]) -> [String: Any] {
        var result = hooks
        for (event, value) in hooks {
            guard let list = value as? [[String: Any]] else { continue }
            let kept = list.filter { !(($0["command"] as? String) ?? "").contains(ConfigFile.marker) }
            if kept.count != list.count { result[event] = kept.isEmpty ? nil : kept }
        }
        return result
    }
}
