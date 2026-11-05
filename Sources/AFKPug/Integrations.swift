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
}

enum AgentIntegrations {
    static var all: [AgentIntegration] { [claude] }

    static func integration(_ id: String) -> AgentIntegration? { all.first { $0.id == id } }

    static let claude = AgentIntegration(
        id: "claude",
        name: "Claude Code",
        configPath: "~/.claude/settings.json",
        isAvailable: {
            FileManager.default.fileExists(atPath: ClaudeHooks.settingsURL.deletingLastPathComponent().path)
        },
        isConnected: { ClaudeHooks.isInstalled() },
        needsUpgrade: { ClaudeHooks.needsUpgrade() },
        connect: { try ClaudeHooks.install() },
        disconnect: { try ClaudeHooks.uninstall() }
    )
}
