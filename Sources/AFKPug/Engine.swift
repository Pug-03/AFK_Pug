import Foundation
import AppKit
import UserNotifications

enum GuardTrip: Equatable {
    case battery(Int)
    case thermal
}

enum PugMood { case sleeping, awake, worried }

/// What happened while the lid was closed.
struct LidSummary: Identifiable {
    let id = UUID()
    let closedAt: Date
    var openedAt: Date?
    let startBattery: Int
    var endBattery: Int
    var peakThermal: ProcessInfo.ThermalState
    var agentsFinished: Int
    var hadBattery: Bool

    var duration: TimeInterval { (openedAt ?? Date()).timeIntervalSince(closedAt) }
}

struct ActivityItem: Identifiable {
    let id = UUID()
    let date: Date
    let icon: String
    let text: String
}

@MainActor
final class Engine: ObservableObject {
    static let shared = Engine()
    private let defaults = UserDefaults.standard

    // MARK: Settings (persisted)

    @Published var agentMode: Bool { didSet { save(agentMode, "agentMode"); tick() } }
    @Published var lidMode: Bool { didSet { save(lidMode, "lidMode"); tick() } }
    @Published var selectedMinutes: Int { didSet { save(selectedMinutes, "selectedMinutes") } }
    @Published var batteryFloor: Int { didSet { save(batteryFloor, "batteryFloor") } }
    @Published var displayOffOnClose: Bool { didSet { save(displayOffOnClose, "displayOffOnClose") } }
    @Published var muteOnClose: Bool { didSet { save(muteOnClose, "muteOnClose") } }
    @Published var lowPowerOnClose: Bool { didSet { save(lowPowerOnClose, "lowPowerOnClose") } }
    @Published var lidOnlyOnPower: Bool { didSet { save(lidOnlyOnPower, "lidOnlyOnPower"); tick() } }
    @Published var notifyAgents: Bool { didSet { save(notifyAgents, "notifyAgents") } }
    @Published var graceMinutes: Int { didSet { save(graceMinutes, "graceMinutes") } }
    @Published var language: AppLanguage { didSet { save(language.rawValue, "language"); L10n.language = language } }
    @Published var detectOtherAgents: Bool { didSet { save(detectOtherAgents, "detectOtherAgents"); tick() } }
    @Published var pauseChatApps: Bool { didSet { save(pauseChatApps, "pauseChatApps") } }
    @Published var lockOnClose: Bool { didSet { save(lockOnClose, "lockOnClose") } }
    @Published var hotkeyEnabled: Bool { didSet { save(hotkeyEnabled, "hotkeyEnabled"); HotKey.setEnabled(hotkeyEnabled) } }
    @Published var phoneTopic: String { didSet { save(phoneTopic, "phoneTopic") } }
    @Published var autoOnPower: Bool { didSet { save(autoOnPower, "autoOnPower"); tick() } }
    @Published var autoApps: String { didSet { save(autoApps, "autoApps") } }
    @Published var keepMusic: Bool { didSet { save(keepMusic, "keepMusic"); tick() } }

    // MARK: Live state

    @Published private(set) var manualOn = false
    @Published private(set) var manualStart: Date?
    @Published private(set) var manualEnd: Date?
    @Published private(set) var holds: [AgentHold] = []
    @Published private(set) var graceUntil: Date?
    @Published private(set) var battery = Sensors.battery()
    @Published private(set) var thermal = Sensors.thermal()
    @Published private(set) var lidClosed = Sensors.lidClosed()
    @Published private(set) var setupDone = false
    @Published private(set) var claudeConnected = ClaudeHooks.isInstalled()
    @Published private(set) var trip: GuardTrip?
    @Published private(set) var isActive = false
    @Published private(set) var lidOverrideOn = false
    @Published var summary: LidSummary?
    @Published private(set) var activity: [ActivityItem] = []
    @Published private(set) var now = Date()
    @Published var setupError: String?
    @Published private(set) var triggerReason: String?
    @Published private(set) var musicPlaying = false
    @Published private(set) var mcpConnected = MCPInstaller.isInstalled()

    private var timer: Timer?
    private var tickCount = 0
    private var wasMuted: Bool?
    private var lowPowerChangedByUs = false
    private var openSummary: LidSummary?
    private var lastDisplayOff = Date.distantPast
    private var procLastBusy: [Int32: Date] = [:]
    private var procFirstSeen: [Int32: Date] = [:]
    private var procNames: [Int32: String] = [:]
    private var ignoredProcs = Set<Int32>()

    private init() {
        let ud = UserDefaults.standard
        let bool = { (key: String, fallback: Bool) -> Bool in ud.object(forKey: key) as? Bool ?? fallback }
        let int = { (key: String, fallback: Int) -> Int in ud.object(forKey: key) as? Int ?? fallback }
        agentMode = bool("agentMode", true)
        lidMode = bool("lidMode", true)
        selectedMinutes = int("selectedMinutes", 120)
        batteryFloor = int("batteryFloor", 15)
        displayOffOnClose = bool("displayOffOnClose", true)
        muteOnClose = bool("muteOnClose", true)
        lowPowerOnClose = bool("lowPowerOnClose", true)
        lidOnlyOnPower = bool("lidOnlyOnPower", false)
        notifyAgents = bool("notifyAgents", true)
        graceMinutes = int("graceMinutes", 2)
        language = AppLanguage(rawValue: ud.string(forKey: "language") ?? "") ?? .system
        detectOtherAgents = bool("detectOtherAgents", true)
        pauseChatApps = bool("pauseChatApps", false)
        lockOnClose = bool("lockOnClose", true)
        hotkeyEnabled = bool("hotkeyEnabled", true)
        phoneTopic = ud.string(forKey: "phoneTopic") ?? ""
        autoOnPower = bool("autoOnPower", false)
        autoApps = ud.string(forKey: "autoApps") ?? ""
        keepMusic = bool("keepMusic", true)
        L10n.language = language
    }

    private func save(_ value: Any, _ key: String) { defaults.set(value, forKey: key) }

    // MARK: Lifecycle

    func boot() {
        Installer.installScripts()
        setupDone = PowerControl.isSetupDone
        if setupDone { Installer.installWatchdog() }
        recoverFromCrash()
        if Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
        HotKey.action = { [weak self] in
            guard let self else { return }
            self.manualOn ? self.stop() : self.start()
        }
        HotKey.setEnabled(hotkeyEnabled)
        log("pawprint.fill", tr("AFK Pug is ready"))
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer!, forMode: .common)
        tick()
    }

    /// Put everything back the way we found it.
    func shutdown() {
        restoreLidChanges()
        if lidOverrideOn || FileManager.default.fileExists(atPath: Paths.lidFlag.path) {
            PowerControl.setSleepDisabled(false)
        }
        PowerControl.setIdleAssertion(false)
    }

    private func recoverFromCrash() {
        if FileManager.default.fileExists(atPath: Paths.lidFlag.path) {
            PowerControl.setSleepDisabled(false)
            log("arrow.uturn.backward", tr("Restored normal lid sleep after an unexpected quit"))
        }
        ChatPauser.resume()
        let lpFlag = Paths.state.appendingPathComponent("lowpower-restore")
        if FileManager.default.fileExists(atPath: lpFlag.path) {
            PowerControl.setLowPower(false)
            try? FileManager.default.removeItem(at: lpFlag)
        }
    }

    // MARK: User actions

    func start() {
        trip = nil
        manualOn = true
        manualStart = Date()
        manualEnd = selectedMinutes > 0 ? Date().addingTimeInterval(TimeInterval(selectedMinutes * 60)) : nil
        log("sun.max.fill", selectedMinutes > 0 ? tr("Awake for %@", Fmt.minutes(selectedMinutes)) : tr("Awake until you stop"))
        tick()
    }

    func stop() {
        guard manualOn else { return }
        manualOn = false
        manualEnd = nil
        manualStart = nil
        log("moon.zzz.fill", tr("Stopped. Back to normal sleep"))
        tick()
    }

    func addTime(minutes: Int) {
        guard manualOn else { return }
        let base = max(manualEnd ?? Date(), Date())
        manualEnd = base.addingTimeInterval(TimeInterval(minutes * 60))
        log("plus.circle.fill", tr("Added %@", Fmt.minutes(minutes)))
    }

    func choose(minutes: Int) {
        selectedMinutes = minutes
        if manualOn {
            manualStart = Date()
            manualEnd = minutes > 0 ? Date().addingTimeInterval(TimeInterval(minutes * 60)) : nil
        }
    }

    func release(_ hold: AgentHold) {
        if hold.id.hasPrefix("proc-"), let pid = Int32(hold.id.dropFirst(5)) { ignoredProcs.insert(pid) }
        HoldStore.release(hold)
        tick()
    }

    func runSetup() {
        setupError = nil
        switch PowerControl.installSudoers() {
        case .success:
            setupDone = PowerControl.isSetupDone
            if setupDone {
                Installer.installWatchdog()
                log("checkmark.seal.fill", tr("Lid-closed mode is ready"))
            } else {
                setupError = tr("Permission was not applied. Please try again.")
            }
        case .failure(let error):
            setupError = error.localizedDescription
        }
        tick()
    }

    func removeSetup() {
        _ = PowerControl.uninstallSudoers()
        setupDone = PowerControl.isSetupDone
        lidOverrideOn = false
    }

    func connectClaude() {
        do {
            try ClaudeHooks.install()
            claudeConnected = true
            log("link", tr("Connected to Claude Code"))
        } catch {
            setupError = error.localizedDescription
        }
    }

    func connectMCP() {
        if MCPInstaller.install() {
            log("cpu", tr("Agents can now ask AFK Pug to stay awake"))
        } else {
            setupError = tr("Could not run the claude command. Is Claude Code installed?")
        }
        mcpConnected = MCPInstaller.isInstalled()
    }

    func disconnectMCP() {
        MCPInstaller.uninstall()
        mcpConnected = MCPInstaller.isInstalled()
    }

    func testPhone() {
        PhoneNotifier.send(topic: phoneTopic, title: "AFK Pug", body: tr("Test notification. Your phone is connected."))
    }

    func disconnectClaude() {
        try? ClaudeHooks.uninstall()
        claudeConnected = ClaudeHooks.isInstalled()
        log("link.badge.plus", tr("Disconnected from Claude Code"))
    }

    // MARK: Derived

    var remaining: TimeInterval? { manualEnd.map { max(0, $0.timeIntervalSince(now)) } }

    var progress: Double {
        guard let start = manualStart, let end = manualEnd else { return 1 }
        let total = end.timeIntervalSince(start)
        return total > 0 ? max(0, min(1, end.timeIntervalSince(now) / total)) : 0
    }

    var mood: PugMood {
        if trip != nil { return .worried }
        return isActive ? .awake : .sleeping
    }

    var headline: String {
        switch trip {
        case .battery: return tr("Low battery, napping")
        case .thermal: return tr("Too hot, cooling down")
        case nil: break
        }
        if manualOn { return manualEnd == nil ? tr("Awake until you stop") : tr("Staying awake") }
        if let reason = triggerReason, holds.isEmpty { return tr("Awake: %@", reason) }
        if !holds.isEmpty { return holds.count == 1 ? tr("Watching 1 agent") : tr("Watching %d agents", holds.count) }
        if let grace = graceUntil, grace > now { return tr("Agents done") }
        return tr("Napping")
    }

    var subline: String {
        switch trip {
        case .battery(let p): return tr("Stopped at %d%%. Plug in to continue", p)
        case .thermal: return tr("Your Mac got too hot, so it can sleep now")
        case nil: break
        }
        if manualOn {
            if let r = remaining { return tr("%@ left", Fmt.clock(r)) }
            return tr("Close the lid. Your work keeps running")
        }
        if !holds.isEmpty { return tr("Awake while they work, then sleeps") }
        if let grace = graceUntil, grace > now { return tr("Sleeping in %@", Fmt.clock(grace.timeIntervalSince(now))) }
        return agentMode ? tr("Wakes when your agents start") : tr("Your Mac sleeps normally")
    }

    var lidReady: Bool { lidMode && setupDone }

    // MARK: Loop

    func tick() {
        now = Date()
        tickCount += 1
        battery = Sensors.battery()
        thermal = Sensors.thermal()

        // Agents
        let previous = holds
        holds = HoldStore.scan(now: now) + scanProcesses()
        handleEvents(HoldStore.consumeEvents())
        if !previous.isEmpty, holds.isEmpty {
            graceUntil = now.addingTimeInterval(TimeInterval(graceMinutes * 60))
        }
        if !holds.isEmpty { graceUntil = nil }
        for hold in holds where !previous.contains(where: { $0.id == hold.id }) {
            log("bolt.fill", tr("%@ started working", hold.displayName))
        }

        // Manual timer
        if manualOn, let end = manualEnd, now >= end {
            manualOn = false
            manualEnd = nil
            manualStart = nil
            log("alarm.fill", tr("Timer finished"))
            notify(tr("Time's up"), tr("AFK Pug let your Mac go back to sleep."))
        }

        // Guards
        updateGuards()

        let agentsWant = agentMode && (!holds.isEmpty || (graceUntil.map { $0 > now } ?? false))
        triggerReason = nil
        musicPlaying = AudioWatcher.isPlaying()
        if keepMusic, musicPlaying { triggerReason = tr("music playing") }
        if autoOnPower, battery.hasBattery, battery.onAC { triggerReason = tr("charger connected") }
        if let app = Triggers.runningApp(from: autoApps) { triggerReason = app }
        let want = trip == nil && (manualOn || agentsWant || triggerReason != nil)
        apply(active: want)

        // Lid
        let closed = Sensors.lidClosed()
        if closed != lidClosed {
            lidClosed = closed
            closed ? lidDidClose() : lidDidOpen()
        }
        if lidClosed, isActive {
            openSummary?.endBattery = battery.percent
            if thermal.rawValue > (openSummary?.peakThermal.rawValue ?? 0) { openSummary?.peakThermal = thermal }
            // Apple Silicon can leave the panel lit under the lid; keep pushing it dark.
            if displayOffOnClose, now.timeIntervalSince(lastDisplayOff) > 30 {
                PowerControl.displaySleepNow()
                lastDisplayOff = now
            }
            if thermal == .serious, lowPowerOnClose, !lowPowerChangedByUs, setupDone { enableLowPower() }
        }
    }

    /// Agents without hooks, found by process and CPU use.
    private func scanProcesses() -> [AgentHold] {
        guard agentMode, detectOtherAgents else { return [] }
        for busy in ProcessWatcher.scan() where !ignoredProcs.contains(busy.pid) {
            procLastBusy[busy.pid] = now
            procNames[busy.pid] = busy.display
            if procFirstSeen[busy.pid] == nil { procFirstSeen[busy.pid] = now }
        }
        // Count as working for 30 s after the last busy sample, so short pauses don't flap.
        for (pid, last) in procLastBusy where now.timeIntervalSince(last) > 30 {
            procLastBusy[pid] = nil
            procFirstSeen[pid] = nil
            procNames[pid] = nil
            ignoredProcs.remove(pid)
        }
        return procLastBusy.keys.sorted().map { pid in
            AgentHold(id: "proc-\(pid)", agent: procNames[pid] ?? "agent", started: procFirstSeen[pid] ?? now, expires: nil, reason: nil)
        }
    }

    private func updateGuards() {
        if let current = trip {
            switch current {
            case .battery:
                if battery.onAC || battery.percent > batteryFloor + 5 { trip = nil }
            case .thermal:
                if thermal.rawValue <= ProcessInfo.ThermalState.fair.rawValue { trip = nil }
            }
            return
        }
        guard isActive || manualOn || !holds.isEmpty || triggerReason != nil else { return }
        if battery.hasBattery, !battery.onAC, battery.percent <= batteryFloor {
            trip = .battery(battery.percent)
            manualOn = false
            log("battery.25percent", tr("Battery at %d%%. Letting the Mac sleep", battery.percent))
            notify(tr("Battery low"), tr("AFK Pug stopped at %d%% so your Mac can sleep safely.", battery.percent))
        } else if thermal == .critical {
            trip = .thermal
            manualOn = false
            log("thermometer.high", tr("Mac too hot. Letting it sleep"))
            notify(tr("Too hot"), tr("AFK Pug stopped so your Mac can cool down."))
        }
    }

    private func apply(active: Bool) {
        let wasActive = isActive
        isActive = active
        PowerControl.setIdleAssertion(active)

        let wantLid = active && lidReady && (!lidOnlyOnPower || battery.onAC)
        if wantLid {
            // Re-check every ~6 s: some macOS builds quietly flip the override back.
            if !lidOverrideOn || tickCount % 3 == 0 {
                if !lidOverrideOn || !PowerControl.sleepDisabled() {
                    lidOverrideOn = PowerControl.setSleepDisabled(true)
                }
            }
        } else if lidOverrideOn {
            PowerControl.setSleepDisabled(false)
            lidOverrideOn = false
        }

        if wasActive, !active, lidClosed {
            // Work is done while the lid is shut: finish up and sleep now.
            finishSummary()
            restoreLidChanges()
            PowerControl.sleepNow()
        }
    }

    private func handleEvents(_ events: [AgentEvent]) {
        for event in events {
            let name = event.agent == "claude" ? "Claude Code" : event.agent
            switch event.kind {
            case .done:
                openSummary?.agentsFinished += 1
                log("checkmark.circle.fill", tr("%@ finished", name))
                if notifyAgents { notify(tr("%@ finished", name), tr("Your agent is done. AFK Pug will let the Mac sleep soon.")) }
            case .waiting:
                log("hand.raised.fill", tr("%@ needs you", name))
                if notifyAgents { notify(tr("%@ needs you", name), tr("Your agent is waiting for your input.")) }
            }
        }
    }

    // MARK: Lid transitions

    private func lidDidClose() {
        guard isActive else { return }
        log("laptopcomputer", tr("Lid closed. Still working"))
        openSummary = LidSummary(closedAt: now, startBattery: battery.percent, endBattery: battery.percent,
                                 peakThermal: thermal, agentsFinished: 0, hadBattery: battery.hasBattery)
        if lockOnClose { ScreenLock.lock() }
        if displayOffOnClose {
            PowerControl.displaySleepNow()
            lastDisplayOff = now
        }
        if pauseChatApps { ChatPauser.pause() }
        if muteOnClose, !(keepMusic && musicPlaying) {
            wasMuted = PowerControl.isMuted()
            if wasMuted == false { PowerControl.setMuted(true) }
        }
        if lowPowerOnClose, setupDone, battery.hasBattery, !battery.onAC { enableLowPower() }
        if !musicPlaying { NSSound(named: "Tink")?.play() }
    }

    private func lidDidOpen() {
        restoreLidChanges()
        if openSummary != nil {
            finishSummary()
            log("sun.horizon.fill", tr("Welcome back"))
        }
    }

    private func enableLowPower() {
        guard !PowerControl.lowPowerOn() else { return }
        if PowerControl.setLowPower(true) {
            lowPowerChangedByUs = true
            Paths.touch(Paths.state.appendingPathComponent("lowpower-restore"))
        }
    }

    private func restoreLidChanges() {
        ChatPauser.resume()
        if let muted = wasMuted, muted == false { PowerControl.setMuted(false) }
        wasMuted = nil
        if lowPowerChangedByUs {
            PowerControl.setLowPower(false)
            lowPowerChangedByUs = false
            try? FileManager.default.removeItem(at: Paths.state.appendingPathComponent("lowpower-restore"))
        }
    }

    private func finishSummary() {
        guard var s = openSummary else { return }
        s.openedAt = Date()
        s.endBattery = battery.percent
        openSummary = nil
        guard s.duration > 20 else { return }
        summary = s
        var body = tr("Lid closed for %@.", Fmt.duration(s.duration))
        if s.hadBattery { body += tr(" Battery %d%% → %d%%.", s.startBattery, s.endBattery) }
        if s.agentsFinished > 0 { body += tr(" %d agent turn(s) finished.", s.agentsFinished) }
        notify(tr("While you were away"), body)
    }

    // MARK: Output

    private func log(_ icon: String, _ text: String) {
        activity.insert(ActivityItem(date: Date(), icon: icon, text: text), at: 0)
        if activity.count > 40 { activity.removeLast(activity.count - 40) }
    }

    private func notify(_ title: String, _ body: String) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        PhoneNotifier.send(topic: phoneTopic, title: title, body: body)
    }
}

enum Fmt {
    static func clock(_ t: TimeInterval) -> String {
        let s = Int(t.rounded(.up))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    static func minutes(_ m: Int) -> String {
        if m <= 0 { return "∞" }
        if m % 60 == 0 { return tr("%dh", m / 60) }
        if m > 60 { return tr("%dh %dm", m / 60, m % 60) }
        return L10n.isThai ? tr("%dm·short", m) : "\(m)m"
    }

    static func duration(_ t: TimeInterval) -> String {
        let m = Int(t / 60)
        if m < 1 { return tr("under a minute") }
        return m >= 60 ? tr("%dh %dm", m / 60, m % 60) : tr("%dm", m)
    }
}
