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

    var duration: TimeInterval { (openedAt ?? Clock.now()).timeIntervalSince(closedAt) }
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
    /// Simulation keeps its settings in a separate domain.
    static let store: UserDefaults = Sim.enabled ? (UserDefaults(suiteName: "com.pug03.afkpug.sim") ?? .standard) : .standard
    private let defaults = Engine.store

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
    /// Lid closed with no external display (docked clamshell use counts as open).
    @Published private(set) var lidClosed = false
    @Published private(set) var setupDone = false
    @Published private(set) var claudeConnected = ClaudeHooks.isInstalled()
    @Published private(set) var trip: GuardTrip?
    @Published private(set) var isActive = false
    @Published private(set) var lidOverrideOn = false
    @Published var summary: LidSummary?
    @Published private(set) var activity: [ActivityItem] = []
    /// Time of the last tick. Not published: views that show durations use their
    /// own TimelineView, so the whole popover isn't re-rendered every 2 s.
    private(set) var now = Clock.now()
    @Published var setupError: String?
    /// Connect failures, shown in Settings next to the button. Cleared on retry.
    @Published private(set) var claudeError: String?
    @Published private(set) var mcpError: String?
    @Published private(set) var mcpBusy = false
    @Published private(set) var triggerReason: String?
    @Published private(set) var musicPlaying = false
    @Published private(set) var mcpConnected = MCPInstaller.isInstalled()

    private var timer: Timer?
    private var tickCount = 0
    private var wasMuted: Bool?
    /// The power source whose Low Power Mode we turned on (restored exactly).
    private var lowPowerChangedSource: PowerControl.PowerSource?
    private var openSummary: LidSummary?
    private var lastDisplayOff = Date.distantPast
    private var procLastBusy: [Int32: Date] = [:]
    private var procFirstSeen: [Int32: Date] = [:]
    private var procNames: [Int32: String] = [:]
    private var ignoredProcs = Set<Int32>()
    private var lastProcScan = Date.distantPast
    /// Lid-closed actions (lock, display off, mute, ...) are currently in effect.
    private(set) var lidEngaged = false
    private var lastOverrideCheck = Date.distantPast
    private var lastOverrideFailure = Date.distantPast
    private var lastReleaseFailure = Date.distantPast
    private var firstTick = true

    private init() {
        let ud = Engine.store
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
        // Older connections lack the PreToolUse / PostToolUse hooks.
        if ClaudeHooks.needsUpgrade(), (try? ClaudeHooks.install()) != nil { log("link", tr("Updated the Claude Code connection")) }
        recoverFromCrash()
        if Bundle.main.bundleIdentifier != nil, !Sim.enabled {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
        HotKey.action = { [weak self] in
            guard let self else { return }
            self.manualOn ? self.stop() : self.start()
        }
        if !Sim.enabled { HotKey.setEnabled(hotkeyEnabled) }
        log("pawprint.fill", tr("AFK Pug is ready"))
        if Sim.headless { tick(); return }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer!, forMode: .common)
        tick()
    }

    /// Put everything back the way we found it.
    func shutdown() {
        restoreLidChanges()
        lidEngaged = false
        openSummary = nil
        if lidOverrideOn || FileManager.default.fileExists(atPath: Paths.lidFlag.path) {
            PowerControl.setSleepDisabled(false)
        }
        PowerControl.setIdleAssertion(false)
        lidOverrideOn = false
        isActive = false
    }

    private func recoverFromCrash() {
        if FileManager.default.fileExists(atPath: Paths.lidFlag.path) {
            PowerControl.setSleepDisabled(false)
            log("arrow.uturn.backward", tr("Restored normal lid sleep after an unexpected quit"))
        }
        ChatPauser.resume()
        if FileManager.default.fileExists(atPath: Paths.lowPowerFlag.path) {
            let text = (try? String(contentsOf: Paths.lowPowerFlag, encoding: .utf8)) ?? ""
            if let source = PowerControl.PowerSource(rawValue: text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                PowerControl.setLowPower(false, source: source)
            }
            try? FileManager.default.removeItem(at: Paths.lowPowerFlag)
        }
        if FileManager.default.fileExists(atPath: Paths.muteFlag.path) {
            PowerControl.setMuted(false)
            try? FileManager.default.removeItem(at: Paths.muteFlag)
        }
    }

    // MARK: User actions

    func start() {
        // A guard trip disables Go AFK; the hotkey must not get around it.
        guard trip == nil else { return }
        manualOn = true
        manualStart = Clock.now()
        manualEnd = selectedMinutes > 0 ? Clock.now().addingTimeInterval(TimeInterval(selectedMinutes * 60)) : nil
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
        let base = max(manualEnd ?? Clock.now(), Clock.now())
        manualEnd = base.addingTimeInterval(TimeInterval(minutes * 60))
        log("plus.circle.fill", tr("Added %@", Fmt.minutes(minutes)))
    }

    func choose(minutes: Int) {
        selectedMinutes = minutes
        if manualOn {
            manualStart = Clock.now()
            manualEnd = minutes > 0 ? Clock.now().addingTimeInterval(TimeInterval(minutes * 60)) : nil
        }
    }

    func release(_ hold: AgentHold) {
        if hold.id.hasPrefix("proc-"), let pid = Int32(hold.id.dropFirst(5)) {
            // Ignored until that process exits; drop it from the list right away.
            ignoredProcs.insert(pid)
            procLastBusy[pid] = nil
            procFirstSeen[pid] = nil
            procNames[pid] = nil
        }
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
        if !PowerControl.sleepDisabled() { lidOverrideOn = false }
    }

    func connectClaude() {
        claudeError = nil
        do {
            try ClaudeHooks.install()
            claudeConnected = true
            log("link", tr("Connected to Claude Code"))
        } catch {
            claudeError = tr("Could not connect: %@", error.localizedDescription)
        }
    }

    /// Runs `claude` (twice) off the main thread.
    func connectMCP() {
        guard !mcpBusy else { return }
        mcpError = nil
        mcpBusy = true
        background({ MCPInstaller.install() }) { [weak self] result in
            guard let self else { return }
            self.mcpBusy = false
            switch result {
            case .success:
                self.log("cpu", tr("Agents can now ask AFK Pug to stay awake"))
            case .failure(.noClaude):
                self.mcpError = tr("Could not find the claude command. Is Claude Code installed?")
            case .failure(.failed(let output)):
                self.mcpError = output.isEmpty ? tr("claude mcp add failed. Please try again.") : output
            }
            self.mcpConnected = Sim.enabled ? (try? result.get()) != nil : MCPInstaller.isInstalled()
        }
    }

    func disconnectMCP() {
        guard !mcpBusy else { return }
        mcpError = nil
        mcpBusy = true
        background({ MCPInstaller.uninstall() }) { [weak self] ok in
            guard let self else { return }
            self.mcpBusy = false
            self.mcpConnected = Sim.enabled ? !ok : MCPInstaller.isInstalled()
            if self.mcpConnected { self.mcpError = tr("Could not find the claude command. Is Claude Code installed?") }
        }
    }

    /// Work off the main thread, result back on it (inline in the headless simulator).
    private func background<T: Sendable>(_ work: @escaping @Sendable () -> T, then: @escaping @MainActor (T) -> Void) {
        if Sim.headless { then(work()); return }
        DispatchQueue.global(qos: .userInitiated).async {
            let value = work()
            DispatchQueue.main.async { MainActor.assumeIsolated { then(value) } }
        }
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

    var remaining: TimeInterval? { manualEnd.map { max(0, $0.timeIntervalSince(Clock.now())) } }

    var progress: Double {
        guard let start = manualStart, let end = manualEnd else { return 1 }
        let total = end.timeIntervalSince(start)
        return total > 0 ? max(0, min(1, end.timeIntervalSince(Clock.now()) / total)) : 0
    }

    /// Agents only count (headline, grace, guards) with Agent mode on.
    var graceActive: Bool { agentMode && (graceUntil.map { $0 > Clock.now() } ?? false) }

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
        if graceActive { return tr("Agents done") }
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
        if triggerReason != nil { return tr("Sleeps normally once that stops") }
        if graceActive, let grace = graceUntil { return tr("Sleeping in %@", Fmt.countdown(grace.timeIntervalSince(Clock.now()))) }
        return agentMode ? tr("Wakes when your agents start") : tr("Your Mac sleeps normally")
    }

    var lidReady: Bool { lidMode && setupDone }

    // MARK: Loop

    func tick() {
        now = Clock.now()
        tickCount += 1
        // Only publish real changes, so SwiftUI isn't invalidated every 2 s.
        let newBattery = Sensors.battery()
        if newBattery != battery { battery = newBattery }
        let newThermal = Sensors.thermal()
        if newThermal != thermal { thermal = newThermal }
        // Read the lid first so this tick's decisions (e.g. sleepnow) never use a stale value.
        let closed = LidSensor.update(now: now)
        if closed != lidClosed { lidClosed = closed }

        // Agents. Hold files are still scanned (and cleaned) with Agent mode off,
        // but then nothing counts: no headline, grace or guard.
        let previous = holds
        let scanned = HoldStore.scan(now: now)
        let newHolds = agentMode ? scanned + scanProcesses() : []
        if newHolds != holds { holds = newHolds }
        // Events left from while the app wasn't running would all fire at once.
        handleEvents(HoldStore.consumeEvents(notBefore: firstTick ? Date().addingTimeInterval(-120) : nil))
        firstTick = false
        if agentMode, !previous.isEmpty, holds.isEmpty {
            graceUntil = now.addingTimeInterval(TimeInterval(max(0, graceMinutes) * 60))
        }
        if (!holds.isEmpty || !agentMode), graceUntil != nil { graceUntil = nil }
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

        // Triggers (before the guards, so they see this tick's reasons)
        var reason: String?
        let music = AudioWatcher.isPlaying()
        if music != musicPlaying { musicPlaying = music }
        if keepMusic, music { reason = tr("music playing") }
        if autoOnPower, battery.hasBattery, battery.onAC { reason = tr("charger connected") }
        if let app = Triggers.runningApp(from: autoApps) { reason = app }
        if reason != triggerReason { triggerReason = reason }

        // Guards
        updateGuards()

        let agentsWant = agentMode && (!holds.isEmpty || (graceUntil.map { $0 > now } ?? false))
        let want = trip == nil && (manualOn || agentsWant || triggerReason != nil)
        let wantLid = want && lidReady && (!lidOnlyOnPower || battery.onAC)
        if want, !isActive {
            // A session starting: re-check a clamshell flag that read Yes without an edge.
            let closed = LidSensor.sessionStarted(now: now)
            if closed != lidClosed { lidClosed = closed }
        }
        // Restore first, while the Mac is surely still awake, then drop the override.
        var sleepAfter = false
        if lidEngaged, !(lidClosed && wantLid) {
            disengageLid()
            sleepAfter = lidClosed
        }
        apply(active: want, wantLid: wantLid)
        if lidEngaged, !lidOverrideOn {
            // The override could not be re-applied; macOS will sleep on its own.
            disengageLid()
            sleepAfter = lidClosed
        }
        // Still shut: work is done (or a guard tripped), so sleep now.
        if sleepAfter { PowerControl.sleepNow() }
        updateLidSession()
    }

    /// Agents without hooks, found by process and CPU use.
    private func scanProcesses() -> [AgentHold] {
        guard agentMode, detectOtherAgents else { return [] }
        // `ps` costs ~25 ms of CPU; every ~5 s is plenty given the 30 s linger below.
        if now.timeIntervalSince(lastProcScan) >= 5 || now < lastProcScan {
            lastProcScan = now
            let found = ProcessWatcher.scan()
            // A released process stays ignored until it exits (not just until it idles).
            ignoredProcs.formIntersection(found.map(\.pid))
            for agent in found where agent.busy && !ignoredProcs.contains(agent.pid) {
                procLastBusy[agent.pid] = now
                procNames[agent.pid] = agent.display
                if procFirstSeen[agent.pid] == nil { procFirstSeen[agent.pid] = now }
            }
        }
        // Count as working for 30 s after the last busy sample, so short pauses don't flap.
        for (pid, last) in procLastBusy where now.timeIntervalSince(last) > 30 {
            procLastBusy[pid] = nil
            procFirstSeen[pid] = nil
            procNames[pid] = nil
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

    private func apply(active: Bool, wantLid: Bool) {
        if active != isActive { isActive = active }
        PowerControl.setIdleAssertion(active)

        if wantLid {
            if !lidOverrideOn {
                // Back off after a failure instead of running sudo every 2 s.
                if now.timeIntervalSince(lastOverrideFailure) >= 30 || now < lastOverrideFailure { enableOverride() }
            } else if now.timeIntervalSince(lastOverrideCheck) >= 6 || now < lastOverrideCheck {
                // Some macOS builds quietly flip the override back.
                lastOverrideCheck = now
                if !PowerControl.sleepDisabled() { enableOverride() }
            }
        } else if lidOverrideOn || FileManager.default.fileExists(atPath: Paths.lidFlag.path) {
            // Keep trying (with the same backoff) until it really is released;
            // the override stays shown as on until then.
            guard now.timeIntervalSince(lastReleaseFailure) >= 30 || now < lastReleaseFailure else { return }
            if PowerControl.setSleepDisabled(false) {
                lidOverrideOn = false
                lastReleaseFailure = .distantPast
            } else {
                lidOverrideOn = true
                lastReleaseFailure = now
                setupDone = PowerControl.isSetupDone
            }
        }
    }

    private func enableOverride() {
        lidOverrideOn = PowerControl.setSleepDisabled(true)
        lastOverrideCheck = now
        if !lidOverrideOn {
            lastOverrideFailure = now
            setupDone = PowerControl.isSetupDone
        }
    }

    /// One rule for every path: lid-closed actions are on exactly while the lid is
    /// shut, we are active and the override really holds the Mac awake. That covers
    /// a session that starts with the lid already closed (or music that starts later),
    /// guard trips, the override dropping (charger unplugged with "only on power"),
    /// and work ending under the lid. Disengaging happens in tick(), before the
    /// override is dropped.
    private func updateLidSession() {
        // LidSensor already requires an edge, or a minute without input for a
        // flag that read closed without one, so a stale flag can't lock anyone out.
        if !lidEngaged, lidClosed, isActive, lidOverrideOn { engageLid() }
        guard lidEngaged else { return }
        openSummary?.endBattery = battery.percent
        if thermal.rawValue > (openSummary?.peakThermal.rawValue ?? 0) { openSummary?.peakThermal = thermal }
        // Apple Silicon can leave the panel lit under the lid; keep pushing it dark.
        if displayOffOnClose, now.timeIntervalSince(lastDisplayOff) > 30 {
            PowerControl.displaySleepNow()
            lastDisplayOff = now
        }
        // Music started after we muted: give the sound back.
        if keepMusic, musicPlaying, wasMuted == false { unmuteIfWeMuted() }
        if thermal == .serious, lowPowerOnClose, lowPowerChangedSource == nil, setupDone { enableLowPower() }
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

    private func engageLid() {
        lidEngaged = true
        log("laptopcomputer", tr("Lid closed. Still working"))
        openSummary = LidSummary(closedAt: now, startBattery: battery.percent, endBattery: battery.percent,
                                 peakThermal: thermal, agentsFinished: 0, hadBattery: battery.hasBattery)
        if lockOnClose { ScreenLock.lock() }
        if displayOffOnClose {
            PowerControl.displaySleepNow()
            lastDisplayOff = now
        }
        if pauseChatApps { ChatPauser.pause() }
        let music = keepMusic && musicPlaying
        // Chime before muting, otherwise it is never heard.
        if !music { playChime() }
        if muteOnClose, !music {
            wasMuted = PowerControl.isMuted()
            if wasMuted == false {
                Paths.touch(Paths.muteFlag)
                PowerControl.setMuted(true)
            }
        }
        if lowPowerOnClose, setupDone, battery.hasBattery, !battery.onAC { enableLowPower() }
    }

    private func disengageLid() {
        lidEngaged = false
        restoreLidChanges()
        if openSummary != nil {
            finishSummary()
            if !lidClosed { log("sun.horizon.fill", tr("Welcome back")) }
        }
    }

    private func playChime() {
        if Sim.enabled { Sim.record("play sound Tink"); return }
        NSSound(named: "Tink")?.play()
    }

    private func unmuteIfWeMuted() {
        if wasMuted == false { PowerControl.setMuted(false) }
        wasMuted = nil
        try? FileManager.default.removeItem(at: Paths.muteFlag)
    }

    /// Only the power source in use (`pmset -b` / `-c`), so the other source's
    /// setting is never touched. The flag file records which one for crash recovery.
    private func enableLowPower() {
        guard !PowerControl.lowPowerOn() else { return }
        let source = PowerControl.PowerSource.current
        if PowerControl.setLowPower(true, source: source) {
            lowPowerChangedSource = source
            Paths.ensure()
            try? source.rawValue.write(to: Paths.lowPowerFlag, atomically: true, encoding: .utf8)
        }
    }

    private func restoreLidChanges() {
        ChatPauser.resume()
        unmuteIfWeMuted()
        if let source = lowPowerChangedSource {
            PowerControl.setLowPower(false, source: source)
            lowPowerChangedSource = nil
            try? FileManager.default.removeItem(at: Paths.lowPowerFlag)
        }
    }

    private func finishSummary() {
        guard var s = openSummary else { return }
        s.openedAt = Clock.now()
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
        if Sim.enabled { Sim.record("log: \(text)") }
        activity.insert(ActivityItem(date: Clock.now(), icon: icon, text: text), at: 0)
        if activity.count > 40 { activity.removeLast(activity.count - 40) }
    }

    private func notify(_ title: String, _ body: String) {
        if Sim.enabled {
            Sim.record("notify: \(title) | \(body)")
            PhoneNotifier.send(topic: phoneTopic, title: title, body: body)
            return
        }
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

    /// Countdown with units ("1m 52s"), so it never reads as a time of day.
    static func countdown(_ t: TimeInterval) -> String {
        let s = max(0, Int(t.rounded(.up)))
        if s >= 3600 { return tr("%dh %dm", s / 3600, (s % 3600) / 60) }
        return s >= 60 ? tr("%dm %ds", s / 60, s % 60) : tr("%ds", s)
    }

    static func duration(_ t: TimeInterval) -> String {
        let m = Int(t / 60)
        if m < 1 { return tr("under a minute") }
        return m >= 60 ? tr("%dh %dm", m / 60, m % 60) : tr("%dm", m)
    }
}
