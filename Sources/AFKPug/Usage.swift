import SwiftUI
import Foundation

// MARK: - Usage limits (how much of each AI's plan quota is used)
//
// Claude Code hands its quota to the status line command; AFK Pug's status line tap
// (Scripts.statusline) saves just the `rate_limits` object to ~/.afkpug/state.
// Codex answers `account/rateLimits/read` on `codex app-server`, asked every few minutes.
// Nothing leaves the Mac, and no credentials are read.

struct UsageWindow: Equatable, Identifiable {
    let key: String
    let label: String
    /// Share of the window used, 0-100.
    let percent: Double
    let resetsAt: Date?
    var id: String { key }

    enum Level: Int { case normal, warning, critical }
    var level: Level { percent >= 95 ? .critical : (percent >= 80 ? .warning : .normal) }
}

struct UsageReport: Equatable {
    let agent: String
    var windows: [UsageWindow]
    var plan: String?
    var updated: Date
}

enum UsageParse {
    /// Claude Code's `rate_limits`: `{"five_hour": {"used_percentage", "resets_at"}, "seven_day": …}`,
    /// or newer builds' server rows `{"limits": [{"kind", "percent", "resets_at", "scope"}]}`.
    static func claude(_ data: Data, now: Date) -> [UsageWindow]? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        if let rows = object["limits"] as? [[String: Any]], !rows.isEmpty {
            return rows.enumerated().compactMap { i, row in
                guard let percent = number(row["percent"]) else { return nil }
                let kind = row["kind"] as? String ?? "limit"
                let scope = ((row["scope"] as? [String: Any])?["model"] as? [String: Any])?["display_name"] as? String
                    ?? ((row["scope"] as? [String: Any])?["surface"] as? [String: Any])?["display_name"] as? String
                var label: String
                switch kind {
                case "session": label = tr("5-hour")
                case "weekly_all": label = tr("Weekly")
                case "weekly_scoped": label = tr("Weekly")
                default: label = kind.replacingOccurrences(of: "_", with: " ").capitalized
                }
                if let scope { label += " · " + scope }
                return window("\(kind)-\(i)", label, percent, date(row["resets_at"]), now: now)
            }
        }
        let known: [(String, String)] = [("five_hour", tr("5-hour")), ("seven_day", tr("Weekly")),
                                         ("seven_day_opus", tr("Weekly") + " · Opus"), ("seven_day_sonnet", tr("Weekly") + " · Sonnet")]
        let windows = known.compactMap { key, label -> UsageWindow? in
            guard let row = object[key] as? [String: Any],
                  let percent = number(row["used_percentage"]) ?? number(row["utilization"]) ?? number(row["percent"]) else { return nil }
            return window(key, label, percent, date(row["resets_at"]), now: now)
        }
        return windows.isEmpty ? nil : windows
    }

    /// The `result` of Codex's `account/rateLimits/read`.
    static func codex(_ result: [String: Any], now: Date) -> (windows: [UsageWindow], plan: String?)? {
        guard let limits = result["rateLimits"] as? [String: Any] else { return nil }
        let windows = ["primary", "secondary"].compactMap { key -> UsageWindow? in
            guard let row = limits[key] as? [String: Any], let percent = number(row["usedPercent"]) else { return nil }
            let minutes = number(row["windowDurationMins"]) ?? 0
            return window(key, label(minutes: minutes), percent, date(row["resetsAt"]), now: now)
        }
        return (windows, limits["planType"] as? String)
    }

    /// Time to a reset: "2h 14m", or "2d 5h" past a day.
    static func until(_ t: TimeInterval) -> String {
        let t = max(60, t)
        guard t >= 86400 else { return Fmt.compact(t) }
        let days = Int(t / 86400), hours = Int(t.truncatingRemainder(dividingBy: 86400) / 3600)
        return hours == 0 ? tr("%dd", days) : tr("%dd %dh", days, hours)
    }

    static func label(minutes: Double) -> String {
        switch minutes {
        case 280...320: return tr("5-hour")
        case 1380...1500: return tr("Daily")
        case 9800...10400: return tr("Weekly")
        case 40000...46000: return tr("Monthly")
        case ..<1: return tr("Limit")
        default: return Fmt.compact(minutes * 60)
        }
    }

    /// A window whose reset has passed starts over at 0 %.
    private static func window(_ key: String, _ label: String, _ percent: Double, _ resets: Date?, now: Date) -> UsageWindow {
        let fresh = resets.map { $0 <= now } ?? false
        return UsageWindow(key: key, label: label, percent: fresh ? 0 : max(0, min(100, percent)), resetsAt: fresh ? nil : resets)
    }

    private static func number(_ value: Any?) -> Double? {
        if let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() { return n.doubleValue.isFinite ? n.doubleValue : nil }
        if let s = value as? String { return Double(s) }
        return nil
    }

    /// Epoch seconds (or milliseconds) or an ISO 8601 string.
    private static func date(_ value: Any?) -> Date? {
        if let n = number(value), n > 0 { return Date(timeIntervalSince1970: n > 1e11 ? n / 1000 : n) }
        guard let s = value as? String else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: s) { return d }
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: s)
    }
}

@MainActor
final class UsageStore: ObservableObject {
    static let shared = UsageStore()

    /// By agent id ("claude", "codex"), in that order on screen.
    @Published private(set) var reports: [UsageReport] = []

    nonisolated static var claudeFile: URL { Paths.state.appendingPathComponent("usage-claude.json") }
    /// Codex is asked this often (each ask starts `codex app-server` for a moment).
    static let codexEvery: TimeInterval = 5 * 60
    /// Data older than this isn't shown: the window it describes may have moved on.
    static let staleAfter: TimeInterval = 12 * 3600

    private var claudeStamp: Date?
    private var codexAsked = Date.distantPast
    private var codexBusy = false
    private var claude: UsageReport?
    private var codex: UsageReport?
    /// Thresholds already reported, per window and reset ("claude|five_hour|1794321000|80").
    private var alerted: Set<String>
    var alert: (String, String) -> Void = { _, _ in }

    private init() {
        alerted = Set(UserDefaults.standard.stringArray(forKey: "usageAlerted") ?? [])
    }

    func tick(now: Date) {
        readClaude(now: now)
        if Self.codexBinary() != nil, !codexBusy, abs(now.timeIntervalSince(codexAsked)) >= Self.codexEvery {
            askCodex(now: now)
        }
        publish(now: now)
    }

    /// The panel opened: a fresher Codex reading if the last one is over a minute old.
    func panelOpened(now: Date) {
        if Self.codexBinary() != nil, !codexBusy, abs(now.timeIntervalSince(codexAsked)) >= 60 { askCodex(now: now) }
    }

    private func readClaude(now: Date) {
        let url = Self.claudeFile
        guard let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else {
            claude = nil; claudeStamp = nil; return
        }
        // Re-read when the tap wrote again, and every tick near a reset (it drops to 0 %).
        if modified != claudeStamp || claude?.windows.contains(where: { ($0.resetsAt ?? .distantFuture) <= now }) == true {
            claudeStamp = modified
            if let data = try? Data(contentsOf: url), let windows = UsageParse.claude(data, now: now) {
                claude = UsageReport(agent: "claude", windows: windows, plan: nil, updated: modified)
            }
        }
    }

    private func askCodex(now: Date) {
        guard let binary = Self.codexBinary() else { return }
        codexAsked = now
        if Sim.enabled {
            if let text = Sim.value("codex-usage") { codexAnswered(text.data(using: .utf8), now: now) }
            return
        }
        codexBusy = true
        DispatchQueue.global(qos: .utility).async {
            let data = Self.fetchCodex(binary)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.codexBusy = false
                    self.codexAnswered(data, now: Clock.now())
                    self.publish(now: Clock.now())
                }
            }
        }
    }

    private func codexAnswered(_ data: Data?, now: Date) {
        guard let data, let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let parsed = UsageParse.codex(object, now: now), !parsed.windows.isEmpty else { return }
        codex = UsageReport(agent: "codex", windows: parsed.windows, plan: parsed.plan, updated: now)
    }

    private func publish(now: Date) {
        let fresh = [claude, codex].compactMap { $0 }.filter { now.timeIntervalSince($0.updated) < Self.staleAfter }
        for report in fresh { checkAlerts(report) }
        if fresh != reports { reports = fresh }
    }

    private func checkAlerts(_ report: UsageReport) {
        let name = AgentIntegrations.displayName(report.agent)
        var changed = false
        for window in report.windows {
            let reset = window.resetsAt.map { String(Int($0.timeIntervalSince1970 / 60)) } ?? "-"
            for threshold in [95, 80] where window.percent >= Double(threshold) {
                let key = "\(report.agent)|\(window.key)|\(reset)|\(threshold)"
                // One alert per crossing: reaching 95 also covers 80.
                if alerted.insert(key).inserted {
                    changed = true
                    if threshold == 95 || !alerted.contains("\(report.agent)|\(window.key)|\(reset)|95") {
                        let when = window.resetsAt.map { tr("Resets in %@", UsageParse.until($0.timeIntervalSince(Clock.now()))) } ?? ""
                        alert(tr("%@ is at %d%% of its %@ limit", name, Int(window.percent), window.label.lowercased()), when)
                    }
                    if threshold == 95 { alerted.insert("\(report.agent)|\(window.key)|\(reset)|80") }
                }
                break
            }
        }
        if changed {
            // Only the recent ones are worth keeping.
            if alerted.count > 200 { alerted = Set(alerted.sorted().suffix(100)) }
            UserDefaults.standard.set(Array(alerted), forKey: "usageAlerted")
        }
    }

    // MARK: Codex

    nonisolated static func codexBinary() -> URL? {
        if Sim.enabled { return Sim.value("codex-usage") == nil ? nil : URL(fileURLWithPath: "/sim/codex") }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = ["\(home)/.local/bin/codex", "/opt/homebrew/bin/codex", "/usr/local/bin/codex",
                          "\(home)/.npm-global/bin/codex", "\(home)/.bun/bin/codex",
                          "/Applications/Codex.app/Contents/Resources/codex"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    /// Starts `codex app-server`, asks for the rate limits and stops it. The `result`
    /// object, or nil after 20 s or on any error.
    nonisolated static func fetchCodex(_ binary: URL) -> Data? {
        let process = Process()
        process.executableURL = binary
        process.arguments = ["app-server"]
        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        env["PATH"] = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", env["PATH"] ?? ""].joined(separator: ":")
        process.environment = env
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let requests = [
            #"{"id":1,"method":"initialize","params":{"clientInfo":{"name":"afkpug","version":"\#(version)"}}}"#,
            #"{"method":"initialized"}"#,
            #"{"id":2,"method":"account/rateLimits/read"}"#,
        ]
        input.fileHandleForWriting.write((requests.joined(separator: "\n") + "\n").data(using: .utf8)!)

        final class Box: @unchecked Sendable { var data: Data? }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        let reader = output.fileHandleForReading
        DispatchQueue.global(qos: .utility).async {
            defer { done.signal() }
            var buffer = Data()
            while true {
                let chunk = reader.availableData
                if chunk.isEmpty { return }
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let line = Data(buffer[buffer.startIndex..<newline])
                    buffer.removeSubrange(buffer.startIndex...newline)
                    guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                          (object["id"] as? NSNumber)?.intValue == 2 else { continue }
                    if let value = object["result"] { box.data = try? JSONSerialization.data(withJSONObject: value) }
                    return
                }
            }
        }
        let answered = done.wait(timeout: .now() + 20) == .success
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        // The reader ends once the pipe closes; only trust its answer after it did.
        if !answered { _ = done.wait(timeout: .now() + 2); return nil }
        return box.data
    }
}

// MARK: - Claude Code status line tap

/// Puts AFK Pug's tap in front of the user's own status line in ~/.claude/settings.json.
/// The original command still runs (and still prints the status line); the tap only
/// saves the quota. Disconnecting puts the original back exactly.
enum ClaudeStatusLine {
    static var settingsURL: URL { ClaudeHooks.settingsURL }
    static let marker = "/bin/afkpug-statusline"
    static var originalFile: URL { Paths.state.appendingPathComponent("statusline-original.json") }

    static func isInstalled() -> Bool {
        guard let json = try? ConfigFile.loadJSON(settingsURL) else { return false }
        return ((json["statusLine"] as? [String: Any])?["command"] as? String)?.contains(marker) == true
    }

    /// Claude Code is set up on this Mac.
    static func isAvailable() -> Bool {
        FileManager.default.fileExists(atPath: settingsURL.deletingLastPathComponent().path)
    }

    static func command(wrapping original: String?) -> String {
        let tap = ConfigFile.shellQuote(Paths.statuslineScript.path)
        guard let original, !original.isEmpty else { return "[ -x \(tap) ] && \(tap); true" }
        // Without the app (tap gone), the original runs as before.
        return "if [ -x \(tap) ]; then \(tap) \(ConfigFile.shellQuote(original)); else \(original); fi"
    }

    /// The user's own command inside one of our wrappers (nil: there was none).
    static func original(from command: String) -> String? {
        let tap = ConfigFile.shellQuote(Paths.statuslineScript.path)
        let head = "if [ -x \(tap) ]; then \(tap) "
        guard command.hasPrefix(head), let elseRange = command.range(of: "; else ", options: .backwards),
              command.hasSuffix("; fi") else { return nil }
        let original = String(command[elseRange.upperBound..<command.index(command.endIndex, offsetBy: -4)])
        return original.isEmpty ? nil : original
    }

    static func install() throws {
        var json = try ConfigFile.loadJSON(settingsURL)
        if let value = json["statusLine"], !(value is [String: Any]) {
            throw ConfigFile.error(tr("%@ has a \"statusLine\" value that is not an object", ConfigFile.display(settingsURL)))
        }
        var line = json["statusLine"] as? [String: Any] ?? [:]
        let current = line["command"] as? String
        if current?.contains(marker) == true { return }
        if let type = line["type"] as? String, type != "command" {
            throw ConfigFile.error(tr("Your Claude Code status line isn't a command, so AFK Pug can't add to it"))
        }
        line["type"] = "command"
        line["command"] = command(wrapping: current)
        json["statusLine"] = line
        Paths.ensure()
        if let data = try? JSONSerialization.data(withJSONObject: ["command": (current as Any?) ?? NSNull()]) {
            try? data.write(to: originalFile, options: .atomic)
        }
        try ConfigFile.saveJSON(json, to: settingsURL)
    }

    static func uninstall() throws {
        var json = try ConfigFile.loadJSON(settingsURL)
        guard var line = json["statusLine"] as? [String: Any], let current = line["command"] as? String,
              current.contains(marker) else { return }
        let saved = (try? Data(contentsOf: originalFile))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["command"] as? String
        if let original = original(from: current) ?? saved {
            line["command"] = original
            json["statusLine"] = line
        } else {
            json.removeValue(forKey: "statusLine")
        }
        try ConfigFile.saveJSON(json, to: settingsURL)
        try? FileManager.default.removeItem(at: originalFile)
        try? FileManager.default.removeItem(at: UsageStore.claudeFile)
    }
}

// MARK: - Card

struct UsageCard: View {
    @ObservedObject var themeStore = ThemeStore.shared
    @ObservedObject var store = UsageStore.shared
    @ObservedObject var engine: Engine

    var body: some View {
        if !store.reports.isEmpty || engine.claudeUsageOffered || engine.claudeUsageError != nil { card }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "gauge.with.dots.needle.67percent").font(.system(size: 12)).foregroundStyle(Theme.accent)
                    .accessibilityHidden(true)
                Text(tr("Usage limits")).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 4)
            }
            ForEach(store.reports, id: \.agent) { report in
                AgentUsage(report: report)
            }
            if engine.claudeUsageOffered {
                HStack(spacing: 8) {
                    Text(tr("See Claude Code's 5-hour and weekly limits here"))
                        .font(.system(size: 11)).foregroundStyle(Theme.sub)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    PillButton(title: tr("Show"), style: .soft) { engine.setClaudeUsage(true) }
                }
            }
            if let error = engine.claudeUsageError { ErrorText(error) }
        }
        .padding(12)
        .cardBackground(radius: 12)
    }

    private struct AgentUsage: View {
        @ObservedObject var themeStore = ThemeStore.shared
        let report: UsageReport

        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(AgentIntegrations.displayName(report.agent)).font(.system(size: 11.5, weight: .semibold))
                    if let plan = report.plan { Text(plan.capitalized).font(.system(size: 10)).foregroundStyle(Theme.sub) }
                    Spacer(minLength: 4)
                    TimelineView(.periodic(from: .now, by: 30)) { _ in
                        Text(Self.age(report.updated)).font(.system(size: 10)).foregroundStyle(Theme.faint)
                    }
                }
                ForEach(report.windows) { window in
                    WindowBar(window: window)
                }
            }
            .accessibilityElement(children: .combine)
        }

        static func age(_ date: Date) -> String {
            let elapsed = Clock.now().timeIntervalSince(date)
            return elapsed < 60 ? tr("just now") : tr("%@ ago", Fmt.compact(elapsed))
        }
    }

    private struct WindowBar: View {
        @ObservedObject var themeStore = ThemeStore.shared
        let window: UsageWindow
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        private var color: Color {
            switch window.level {
            case .normal: return Theme.accent
            case .warning: return Theme.waitText
            case .critical: return Theme.warn
            }
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(window.label).font(.system(size: 10.5)).foregroundStyle(Theme.sub).lineLimit(1)
                    Spacer(minLength: 4)
                    if let reset = window.resetsAt {
                        TimelineView(.periodic(from: .now, by: 30)) { _ in
                            Text(tr("Resets in %@", UsageParse.until(reset.timeIntervalSince(Clock.now()))))
                                .font(.system(size: 10).monospacedDigit()).foregroundStyle(Theme.faint).lineLimit(1)
                        }
                    }
                    Text("\(Int(window.percent.rounded()))%")
                        .font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(window.level == .normal ? Theme.text : color)
                        .contentTransition(.numericText())
                }
                GeometryReader { box in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.line)
                        Capsule().fill(color)
                            .frame(width: max(window.percent > 0 ? 4 : 0, box.size.width * window.percent / 100))
                    }
                }
                .frame(height: 5)
                .animation(reduceMotion ? nil : Theme.smooth, value: window.percent)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(window.label) \(Int(window.percent.rounded()))%")
        }
    }
}
