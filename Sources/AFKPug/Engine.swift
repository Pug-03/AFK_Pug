import Foundation
import AppKit
import UserNotifications

enum GuardTrip: Equatable {
    case battery(Int)
    case thermal
}


/// What besides agents and the timer keeps the Mac awake.
enum TriggerKind: Equatable {
    case music
    case charger
    case app(String)
}

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
    nonisolated(unsafe) static let store: UserDefaults = Sim.enabled ? (UserDefaults(suiteName: "com.pug03.afkpug.sim") ?? .standard) : .standard
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
    /// Keep the screen on for agents: -1 off, 0 while they work, or minutes after they finish.
    @Published var keepScreenMinutes: Int { didSet { save(keepScreenMinutes, "keepScreenMinutes") } }
    @Published private(set) var keepingScreenOn = false
    @Published var language: AppLanguage { didSet { save(language.rawValue, "language"); L10n.language = language } }
    @Published var detectOtherAgents: Bool { didSet { save(detectOtherAgents, "detectOtherAgents"); tick() } }
    @Published var pauseChatApps: Bool { didSet { save(pauseChatApps, "pauseChatApps") } }
    @Published var lockOnClose: Bool { didSet { save(lockOnClose, "lockOnClose") } }
    @Published var hotkeyEnabled: Bool { didSet { save(hotkeyEnabled, "hotkeyEnabled"); HotKey.setEnabled(hotkeyEnabled) } }
    @Published var phoneTopic: String { didSet { save(phoneTopic, "phoneTopic") } }
    @Published var autoOnPower: Bool { didSet { save(autoOnPower, "autoOnPower"); tick() } }
    @Published var autoApps: String { didSet { save(autoApps, "autoApps") } }
    @Published var keepMusic: Bool { didSet { save(keepMusic, "keepMusic"); tick() } }
    @Published var checkUpdates: Bool { didSet { save(checkUpdates, "checkUpdates") } }
    @Published var menuBarStatus: Bool { didSet { save(menuBarStatus, "menuBarStatus"); updateMenuBarText() } }
    /// Beside the icon: time left or agents working. Minute resolution, so it rarely redraws.
    @Published private(set) var menuBarText: String?

    // MARK: Live state

    /// A newer release the user hasn't dismissed.
    @Published private(set) var update: AvailableUpdate?
    @Published private(set) var updateWorking = false
    @Published private(set) var updateMessage: String?
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
    /// Connected state and last error per integration id (see AgentIntegrations).
    @Published private(set) var connected: [String: Bool] = [:]
    @Published private(set) var integrationErrors: [String: String] = [:]
    /// First-run walkthrough (permission, Claude Code / other agents, open at login).
    @Published var showOnboarding = !Engine.store.bool(forKey: "onboardingDone")
    @Published private(set) var trip: GuardTrip?
    @Published private(set) var isActive = false
    @Published private(set) var lidOverrideOn = false
    @Published var summary: LidSummary?
    @Published private(set) var activity: [ActivityItem] = []
    /// Time of the last tick. Not published: views that show durations use their
    /// own TimelineView, so the whole popover isn't re-rendered every 2 s.
    private(set) var now = Clock.now()
    @Published var setupError: String?
    @Published private(set) var setupWorking = false
    @Published private(set) var launchAtLogin = LoginItem.state
    @Published private(set) var loginError: String?
    @Published private(set) var uninstalling = false
    /// Apps producing sound right now (shown next to "Keep music playing").
    @Published private(set) var musicApps: [String] = []
    private var snoozeMusic = false
    private var snoozeCharger = false
    private var snoozeApp: String?
    /// Set once uninstall starts: the engine never ticks again.
    @Published private(set) var uninstalledAll = false
    @Published private(set) var uninstallErrors: [String] = []
    /// Connect failures, shown in Settings next to the button. Cleared on retry.
    @Published private(set) var claudeError: String?
    @Published private(set) var mcpError: String?
    @Published private(set) var mcpBusy = false
    @Published private(set) var triggerReason: String?
    @Published private(set) var triggerKind: TriggerKind?
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
    /// wantLid from the last tick: lid actions only engage while lid mode is really wanted.
    private var lastWantLid = false
    /// When the last agent hold ended; grace is derived from the current graceMinutes.
    private var holdsEndedAt: Date?
    /// Last time audio was heard (music trigger debounce) and whether it was heard around the close.
    private var lastMusicHeard: Date?
    private var musicAtClose = false
    private var closedAt: Date?
    /// Guard hysteresis and notification rate limits.
    private var acSince: Date?
    private var coolSince: Date?
    private var lastBatteryNotice = Date.distantPast
    /// One early warning per discharge, this many points above the floor.
    static let batteryWarningMargin = 5
    private var lowBatteryWarned = false
    private var lastThermalNotice = Date.distantPast
    private var lastTickTime: Date?
    /// "finished" events waiting 10 s to make sure the agent really stopped. One per
    /// session (hold id `<agent>-<sid>`); events from older hooks carry no session.
    private var pendingDone: [(agent: String, holdId: String?, at: Date)] = []
    /// Agent notifications: at most one per agent + kind per `noticeWindow`; the rest
    /// are summed up and sent as one ("Claude Code finished 5 tasks") when it ends.
    static let noticeWindow: TimeInterval = 60
    private var lastNotice: [String: Date] = [:]
    private var heldNotices: [String: (agent: String, kind: AgentEvent.Kind, count: Int)] = [:]
    /// Agent processes seen while that agent's hooks held the Mac awake: the hooks
    /// report them, so process detection leaves them alone until they exit.
    private var hookedProcs: [Int32: String] = [:]

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
        keepScreenMinutes = int("keepScreenMinutes", -1)
        language = AppLanguage(rawValue: ud.string(forKey: "language") ?? "") ?? .system
        detectOtherAgents = bool("detectOtherAgents", true)
        pauseChatApps = bool("pauseChatApps", false)
        lockOnClose = bool("lockOnClose", true)
        hotkeyEnabled = bool("hotkeyEnabled", true)
        phoneTopic = ud.string(forKey: "phoneTopic") ?? ""
        autoOnPower = bool("autoOnPower", false)
        autoApps = ud.string(forKey: "autoApps") ?? ""
        keepMusic = bool("keepMusic", true)
        checkUpdates = bool("checkUpdates", true)
        menuBarStatus = bool("menuBarStatus", false)
        L10n.language = language
    }

    private func save(_ value: Any, _ key: String) { defaults.set(value, forKey: key) }

    // MARK: Lifecycle

    func boot() {
        Paths.writeAppPid()
        Installer.installScripts()
        // Replaced by "a live hook hold exists" (see scanProcesses).
        Engine.store.removeObject(forKey: "hooksSeenAgents")
        setupDone = PowerControl.isSetupDone
        if setupDone { Installer.installWatchdog() }
        // Older connections lack the PreToolUse / PostToolUse hooks.
        for item in AgentIntegrations.all where item.needsUpgrade() {
            if (try? item.connect()) != nil { log("link", tr("Updated the %@ connection", item.name)) }
        }
        refreshIntegrations()
        recoverFromCrash()
        if !Engine.store.bool(forKey: "didFirstRun") {
            Engine.store.set(true, forKey: "didFirstRun")
            if launchAtLogin == .off, !Sim.enabled { setLaunchAtLogin(true) }
        }
        launchAtLogin = LoginItem.state
        if MCPInstaller.providedByPlugin {
            // The plugin brings its own MCP server: drop the user-scope duplicate.
            if MCPInstaller.isInstalled() {
                background({ MCPInstaller.uninstall() }) { [weak self] _ in
                    self?.mcpConnected = Sim.enabled ? false : MCPInstaller.isInstalled()
                }
            }
        } else if MCPInstaller.needsRefresh() {
            background({ MCPInstaller.install() }) { _ in }
        }
        if Bundle.main.bundleIdentifier != nil, !Sim.enabled {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
        HotKey.action = { [weak self] in
            guard let self else { return }
            self.manualOn ? self.stop() : self.start()
        }
        if !Sim.enabled { HotKey.setEnabled(hotkeyEnabled) }
        log("power", tr("AFK Pug is ready"))
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
        PowerControl.setDisplayAssertion(false)
        keepingScreenOn = false
        lidOverrideOn = false
        isActive = false
        Paths.removeAppPid()
    }

    private func recoverFromCrash() {
        if FileManager.default.fileExists(atPath: Paths.lidFlag.path) {
            if PowerControl.setSleepDisabled(false) {
                log("arrow.uturn.backward", tr("Restored normal lid sleep after an unexpected quit"))
            } else {
                // Keep lidOverrideOn so apply() keeps retrying the release.
                lidOverrideOn = true
                lastReleaseFailure = Clock.now()
                log("exclamationmark.triangle.fill", tr("Couldn't restore normal lid sleep. Press Set up to fix the permission."))
            }
        }
        ChatPauser.resume()
        if FileManager.default.fileExists(atPath: Paths.lowPowerFlag.path) {
            let text = (try? String(contentsOf: Paths.lowPowerFlag, encoding: .utf8)) ?? ""
            if let source = PowerControl.PowerSource(rawValue: text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                if PowerControl.setLowPower(false, source: source) { try? FileManager.default.removeItem(at: Paths.lowPowerFlag) }
            } else {
                try? FileManager.default.removeItem(at: Paths.lowPowerFlag)
            }
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

    /// The last agent was dismissed with its × rather than finishing, so don't say it's done.
    private var releasedByHand = false

    func release(_ hold: AgentHold) {
        if hold.id.hasPrefix("proc-"), let pid = Int32(hold.id.dropFirst(5)) {
            // Ignored until that process exits; drop it from the list right away.
            ignoredProcs.insert(pid)
            procLastBusy[pid] = nil
            procFirstSeen[pid] = nil
            procNames[pid] = nil
        }
        HoldStore.release(hold)
        log("xmark.circle", tr("Stopped watching %@", hold.logName))
        releasedByHand = true
        tick()
        // A tick blocks the main thread for tens of ms: keep the next one out of the row's animation.
        timer?.fireDate = Date().addingTimeInterval(2)
    }

    /// The admin dialog blocks, so it runs off the main thread; the UI shows "Working…".
    func runSetup() {
        guard !setupWorking else { return }
        setupError = nil
        setupWorking = true
        background({ PowerControl.installSudoers() }) { [weak self] result in self?.finishSetup(result) }
    }

    private func finishSetup(_ result: Result<Void, PowerControl.AdminError>) {
        setupWorking = false
        switch result {
        case .success:
            setupDone = PowerControl.isSetupDone
            if setupDone {
                Installer.installWatchdog()
                log("checkmark.seal.fill", tr("Lid-closed mode is ready"))
            } else {
                setupError = tr("Permission was not applied. Please try again.")
            }
        case .failure(let error):
            setupError = Engine.describe(error)
        }
        tick()
    }

    static func describe(_ error: PowerControl.AdminError) -> String { error.message }

    func removeSetup() {
        guard !setupWorking else { return }
        setupWorking = true
        background({ PowerControl.uninstallSudoers() }) { [weak self] result in
            guard let self else { return }
            self.setupWorking = false
            if case .failure(let error) = result, error != .cancelled { self.setupError = Engine.describe(error) }
            self.setupDone = PowerControl.isSetupDone
            if !PowerControl.sleepDisabled() { self.lidOverrideOn = false }
        }
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

    /// Something besides agents is keeping the Mac awake, so "Allow sleep" makes sense.
    /// Never during a guard trip: the Mac is already allowed to sleep.
    var canSleepNow: Bool { trip == nil && (manualOn || triggerReason != nil || graceActive) }

    /// Ends the manual session and the grace period, and snoozes triggers (music,
    /// charger, apps) until each one goes away. Agents still working keep it awake.
    func sleepNow() {
        manualOn = false
        manualEnd = nil
        manualStart = nil
        holdsEndedAt = nil
        graceUntil = nil
        if musicPlaying { snoozeMusic = true }
        if battery.onAC { snoozeCharger = true }
        snoozeApp = Triggers.runningApp(from: autoApps)
        log("moon.zzz.fill", tr("Sleep allowed"))
        tick()
    }

    /// afkpug://start?minutes=90, afkpug://stop, afkpug://toggle, afkpug://sleep-now
    func handle(url: URL) {
        guard url.scheme?.lowercased() == "afkpug" else { return }
        let command = (url.host ?? url.path).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        switch command {
        case "start":
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            if let text = items.first(where: { $0.name == "minutes" })?.value {
                guard let minutes = Int(text), (0...1440).contains(minutes) else { return }
                selectedMinutes = minutes
            }
            if !manualOn { start() } else { choose(minutes: selectedMinutes) }
        case "stop": stop()
        case "toggle": manualOn ? stop() : start()
        case "sleep-now", "sleepnow": sleepNow()
        default: break
        }
    }

    // MARK: Launch at login / uninstall

    func setLaunchAtLogin(_ on: Bool) {
        loginError = nil
        do { try LoginItem.set(on) } catch { loginError = tr("Could not change Open at Login: %@", error.localizedDescription) }
        launchAtLogin = LoginItem.state
    }

    /// Removes hooks, MCP registration, watchdog, permission and ~/.afkpug, then quits.
    func uninstallEverything() {
        guard !uninstalling else { return }
        uninstalling = true
        uninstalledAll = true
        manualOn = false
        manualEnd = nil
        manualStart = nil
        shutdown()
        timer?.invalidate()
        background({ Uninstaller.run() }) { [weak self] report in
            guard let self else { return }
            self.uninstalling = false
            self.uninstallErrors = report.errors
            if Sim.enabled {
                Sim.record("uninstall finished (\(report.errors.count) problem(s))")
            } else {
                Engine.store.removePersistentDomain(forName: Bundle.main.bundleIdentifier ?? "com.pug03.afkpug")
                if report.errors.isEmpty { NSApp.terminate(nil) }
            }
        }
    }

    // MARK: Updates

    /// At most once a day, and not while the Mac is working under the lid.
    private func checkForUpdatesIfDue() {
        guard checkUpdates, !lidClosed, !updateWorking else { return }
        let last = Engine.store.double(forKey: "lastUpdateCheck")
        let sinceLast = now.timeIntervalSince1970 - last
        guard sinceLast >= Updater.checkEvery || sinceLast < 0 else { return }
        if Sim.enabled, Sim.value("latest-release") == nil { return }
        Engine.store.set(now.timeIntervalSince1970, forKey: "lastUpdateCheck")
        Updater.fetchLatest { [weak self] latest in self?.received(latest, manual: false) }
    }

    func checkForUpdatesNow() {
        guard !updateWorking else { return }
        updateWorking = true
        updateMessage = nil
        Engine.store.set(now.timeIntervalSince1970, forKey: "lastUpdateCheck")
        Engine.store.removeObject(forKey: "dismissedUpdate")
        Updater.fetchLatest { [weak self] latest in
            self?.updateWorking = false
            self?.received(latest, manual: true)
        }
    }

    private func received(_ latest: AvailableUpdate?, manual: Bool) {
        guard let latest else {
            if manual { updateMessage = tr("Couldn't check for updates.") }
            return
        }
        guard Updater.isNewer(latest.version, than: Updater.currentVersion) else {
            update = nil
            if manual { updateMessage = tr("You're on the latest version.") }
            return
        }
        guard Engine.store.string(forKey: "dismissedUpdate") != latest.version else { return }
        if latest != update {
            update = latest
            log("arrow.down.circle", tr("AFK Pug %@ is available", latest.version))
        }
    }

    func dismissUpdate() {
        if let update { Engine.store.set(update.version, forKey: "dismissedUpdate") }
        update = nil
        updateMessage = nil
    }

    /// Installs in place when it can: quits (restoring everything) and reopens the new
    /// version. Anywhere else, the release page opens instead.
    func installUpdate() {
        guard let update, !updateWorking else { return }
        guard update.zip != nil, let target = Updater.installTarget else {
            NSWorkspace.shared.open(update.page)
            return
        }
        updateWorking = true
        updateMessage = nil
        let pid = getpid()
        Updater.download(update) { [weak self] downloaded in
            let result = downloaded.flatMap { Updater.prepare(zip: $0, for: update) }.flatMap { app in
                Updater.launchSwap(app: app, target: target, waitingFor: pid) ? Result<Void, Updater.Failure>.success(()) : .failure(.cantLaunch)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.updateWorking = false
                    switch result {
                    case .success:
                        Sim.record("update: quitting to install \(update.version)")
                        if !Sim.enabled { NSApp.terminate(nil) }
                    case .failure(let failure):
                        self.updateMessage = failure.message
                    }
                }
            }
        }
    }

    /// Runs `claude` (twice) off the main thread.
    func connectMCP() {
        guard !mcpBusy else { return }
        mcpError = nil
        if MCPInstaller.providedByPlugin {
            mcpError = tr("The AFK Pug plugin for Claude Code already gives agents these tools.")
            return
        }
        mcpBusy = true
        background({ MCPInstaller.install() }) { [weak self] result in
            guard let self else { return }
            self.mcpBusy = false
            switch result {
            case .success:
                self.log("cpu", tr("Agents can now ask AFK Pug to stay awake"))
            case .failure(.noClaude):
                self.mcpError = tr("Could not find the claude command. Is Claude Code installed?")
            case .failure(.translocated):
                self.mcpError = tr("Move AFK Pug to the Applications folder first, then connect again.")
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
            if self.mcpConnected { self.mcpError = tr("Could not disconnect. In Terminal run: claude mcp remove --scope user afkpug") }
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

    // MARK: Agent integrations

    func refreshIntegrations() {
        // Plugin installed after the settings.json hooks: every event would fire twice.
        if ClaudeHooks.doubledByPlugin(), (try? ClaudeHooks.install()) != nil {
            log("link", tr("Updated the %@ connection", AgentIntegrations.claude.name))
        }
        var state: [String: Bool] = [:]
        for item in AgentIntegrations.all { state[item.id] = item.isConnected() }
        if state != connected { connected = state }
        let claude = state["claude"] ?? false
        if claude != claudeConnected { claudeConnected = claude }
    }

    func connect(_ id: String) {
        guard let item = AgentIntegrations.integration(id) else { return }
        integrationErrors[id] = nil
        do {
            try item.connect()
            log("link", tr("Connected to %@", item.name))
        } catch {
            integrationErrors[id] = tr("Could not connect: %@", error.localizedDescription)
        }
        refreshIntegrations()
    }

    func disconnect(_ id: String) {
        guard let item = AgentIntegrations.integration(id) else { return }
        integrationErrors[id] = nil
        do {
            try item.disconnect()
            // Its hook holds would never be released now (no Stop hook runs any more),
            // and process detection takes over for a running agent.
            HoldStore.releaseAll(agent: item.id)
            log("link.badge.plus", tr("Disconnected from %@", item.name))
        } catch {
            integrationErrors[id] = tr("Could not disconnect: %@", error.localizedDescription)
        }
        refreshIntegrations()
    }

    func finishOnboarding() {
        Engine.store.set(true, forKey: "onboardingDone")
        showOnboarding = false
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

    /// Agents only count (headline, grace, guards) with Agent mode on. A guard trip
    /// overrides grace: the Mac may sleep right away.
    var graceActive: Bool { trip == nil && agentMode && (graceUntil.map { $0 > Clock.now() } ?? false) }

    /// Holds that only wait for a Claude usage limit to reset.
    var waitingAgents: Int { holds.filter(\.isUsageLimitWait).count }

    /// Seconds until a thermal trip can clear (the Mac has to stay cool for 5 min);
    /// nil when there is no thermal trip or the Mac is still too hot to start counting.
    var thermalCooldownRemaining: TimeInterval? {
        guard trip == .thermal, let since = coolSince else { return nil }
        return max(0, Engine.coolDown - Clock.now().timeIntervalSince(since))
    }
    static let coolDown: TimeInterval = 300

    /// A battery trip that only clears once a charger is connected (the battery
    /// alone won't climb 5 % above the floor while the Mac is in use).
    var batteryTripNeedsCharger: Bool {
        if case .battery = trip { return !battery.onAC }
        return false
    }

    var headline: String {
        switch trip {
        case .battery: return tr("Low battery, napping")
        case .thermal: return tr("Too hot, cooling down")
        case nil: break
        }
        if manualOn { return manualEnd == nil ? tr("Awake until you stop") : tr("Staying awake") }
        if let reason = triggerReason, holds.isEmpty { return tr("Awake: %@", reason) }
        if !holds.isEmpty, waitingAgents == holds.count { return tr("Waiting for the usage limit") }
        if !holds.isEmpty { return holds.count == 1 ? tr("Watching 1 agent") : tr("Watching %d agents", holds.count) }
        if graceActive { return tr(releasedByHand ? "Stopped watching" : "Agents done") }
        return tr("Idle")
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
        switch triggerKind {
        case .music: return tr("Sleeps normally once the music stops")
        case .charger: return tr("Sleeps normally once you unplug")
        case .app(let name): return tr("Sleeps normally once %@ quits", name)
        case nil: if triggerReason != nil { return tr("Sleeps normally once that stops") }
        }
        if graceActive, let grace = graceUntil {
            return tr(keepingScreenOn ? "Screen on. Sleeping in %@" : "Sleeping in %@", Fmt.countdown(grace.timeIntervalSince(Clock.now())))
        }
        return agentMode ? tr("Wakes when your agents start") : tr("Your Mac sleeps normally")
    }

    var lidReady: Bool { lidMode && setupDone }

    // MARK: Loop

    func tick() {
        // After uninstall nothing may run again (it would recreate files and re-arm).
        guard !uninstalledAll else { return }
        now = Clock.now()
        tickCount += 1
        if let last = lastTickTime, now < last.addingTimeInterval(-1) { clockWentBack(by: last.timeIntervalSince(now)) }
        lastTickTime = now
        // Only publish real changes, so SwiftUI isn't invalidated every 2 s.
        let newBattery = Sensors.battery()
        if newBattery != battery { battery = newBattery }
        let newThermal = Sensors.thermal()
        if newThermal != thermal { thermal = newThermal }
        // Audio before the lid, so a close in this same tick knows music was playing.
        let audio = AudioWatcher.current()
        if audio.playing { lastMusicHeard = now }
        // Read the lid first so this tick's decisions (e.g. sleepnow) never use a stale value.
        let closed = LidSensor.update(now: now)
        if closed != lidClosed { lidClosed = closed; lidChanged(closed) }

        // Agents. Hold files are still scanned (and cleaned) with Agent mode off,
        // but then nothing counts: no headline, grace or guard.
        let previous = holds
        let scanned = HoldStore.scan(now: now)
        let newHolds = agentMode ? scanned + scanProcesses(hookHolds: scanned) : []
        if newHolds != holds { holds = newHolds }
        // Events left from while the app wasn't running would all fire at once.
        handleEvents(HoldStore.consumeEvents(notBefore: firstTick ? Date().addingTimeInterval(-120) : nil))
        firstTick = false
        if agentMode, !previous.isEmpty, holds.isEmpty { holdsEndedAt = now }
        if !holds.isEmpty || !agentMode { holdsEndedAt = nil }
        if !holds.isEmpty { releasedByHand = false }
        let newGrace = holdsEndedAt.map { $0.addingTimeInterval(graceLength) }
        if newGrace != graceUntil { graceUntil = newGrace }
        if let g = graceUntil, g <= now { holdsEndedAt = nil; graceUntil = nil }
        for hold in holds where !previous.contains(where: { $0.id == hold.id }) {
            log("bolt.fill", tr("%@ started working", hold.logName))
        }
        confirmFinished()
        flushHeldNotices()
        checkForUpdatesIfDue()

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
        var kind: TriggerKind?
        // A short gap between tracks must not end the session.
        let musicOn = lastMusicHeard.map { now.timeIntervalSince($0) < 30 && now >= $0 } ?? false
        if musicOn != musicPlaying { musicPlaying = musicOn }
        // With the lid closed, music only counts if it was already playing when the lid
        // closed: an idle audio stream must not keep a Mac in a bag awake.
        let newApps = musicOn ? audio.apps : []
        if newApps != musicApps { musicApps = newApps }
        // "Allow sleep" snoozes a trigger until its condition goes away.
        if snoozeMusic, !musicOn { snoozeMusic = false }
        if snoozeCharger, !battery.onAC { snoozeCharger = false }
        let app = Triggers.runningApp(from: autoApps)
        if let snoozed = snoozeApp, app != snoozed { snoozeApp = nil }
        if keepMusic, musicOn, !snoozeMusic, !lidClosed || musicAtClose { reason = tr("music playing"); kind = .music }
        if autoOnPower, battery.hasBattery, battery.onAC, !snoozeCharger { reason = tr("charger connected"); kind = .charger }
        if let app, app != snoozeApp { reason = app; kind = .app(app) }
        if reason != triggerReason { triggerReason = reason }
        if kind != triggerKind { triggerKind = kind }

        // Guards
        updateGuards()

        let agentsWant = agentMode && (!holds.isEmpty || (graceUntil.map { $0 > now } ?? false))
        let want = trip == nil && (manualOn || agentsWant || triggerReason != nil)
        let wantLid = want && lidReady && (!lidOnlyOnPower || battery.onAC)
        if want, !isActive {
            // A session starting: re-check a clamshell flag that read Yes without an edge.
            let closed = LidSensor.sessionStarted(now: now)
            if closed != lidClosed { lidClosed = closed; lidChanged(closed) }
        }
        let wasActiveBefore = isActive
        // About to sleep with the lid shut: nothing can report after this tick.
        let goingToSleep = isActive && lidClosed && !wantLid
        if goingToSleep { confirmFinished(force: true) }
        // Restore first, while the Mac is surely still awake, then drop the override.
        var sleepAfter = false
        if lidEngaged, !(lidClosed && wantLid) {
            disengageLid()
            sleepAfter = lidClosed
        }
        lastWantLid = wantLid
        // Dropping the override can put a closed Mac to sleep at once: send messages first.
        if goingToSleep { PhoneNotifier.flush(timeout: 4) }
        apply(active: want, wantLid: wantLid)
        updateKeepScreen()
        if lidEngaged, !lidOverrideOn {
            // The override could not be re-applied; macOS will sleep on its own.
            disengageLid()
            sleepAfter = lidClosed
        }
        // Session ended while the lid is most likely still shut after a bump.
        if wasActiveBefore, !isActive, !sleepAfter, LidSensor.probablyStillClosed(now: now) { sleepAfter = true }
        // Still shut: work is done (or a guard tripped), so sleep now.
        if sleepAfter { PowerControl.sleepNow() }
        updateLidSession()
        updateMenuBarText()
    }

    /// Staying on after the agents finish only counts on the charger with the lid open,
    /// and not after an agent was dismissed. Losing any of these shortens the wait at once.
    private var screenWaitApplies: Bool {
        keepScreenMinutes > 0 && agentMode && battery.onAC && !lidClosed && !releasedByHand
    }

    /// How long after the last agent the Mac stays awake.
    var graceLength: TimeInterval {
        TimeInterval(max(0, graceMinutes, screenWaitApplies ? keepScreenMinutes : 0) * 60)
    }

    private func updateKeepScreen() {
        let wanted = keepScreenMinutes >= 0 && trip == nil && agentMode && battery.onAC && !lidClosed
            && (!holds.isEmpty || (screenWaitApplies && (graceUntil.map { $0 > now } ?? false)))
        PowerControl.setDisplayAssertion(wanted)
        if wanted != keepingScreenOn { keepingScreenOn = wanted }
    }

    private func updateMenuBarText() {
        var text: String?
        if menuBarStatus, trip == nil {
            if manualOn {
                text = manualEnd.map { Fmt.hoursMinutes($0.timeIntervalSince(now)) }
            } else if agentMode, !holds.isEmpty {
                text = "\(holds.count)"
            } else if graceActive, let until = graceUntil {
                text = Fmt.hoursMinutes(until.timeIntervalSince(now))
            }
        }
        if text != menuBarText { menuBarText = text }
    }

    /// Report "finished" only if the session didn't pick the work up again within 10 s
    /// (its hold `<agent>-<sid>` is back). Another session of the same agent working
    /// doesn't hide it.
    private func confirmFinished(force: Bool = false) {
        guard !pendingDone.isEmpty else { return }
        var keep: [(agent: String, holdId: String?, at: Date)] = []
        var finished: [String: Int] = [:]
        var order: [String] = []
        for item in pendingDone {
            if let id = item.holdId, holds.contains(where: { $0.id == id }) { continue }   // resumed: drop it
            if !force, now.timeIntervalSince(item.at) < 10, now >= item.at { keep.append(item); continue }
            openSummary?.agentsFinished += 1
            log("checkmark.circle.fill", tr("%@ finished", AgentIntegrations.displayName(item.agent)))
            if finished[item.agent] == nil { order.append(item.agent) }
            finished[item.agent, default: 0] += 1
        }
        pendingDone = keep
        for agent in order { agentNotice(agent, .done, count: finished[agent] ?? 1) }
    }

    /// Posts an agent notification, or holds it back if this agent + kind was already
    /// notified within the window (a burst of short turns is one notification).
    private func agentNotice(_ agent: String, _ kind: AgentEvent.Kind, count: Int = 1) {
        guard notifyAgents else { return }
        let key = "\(agent)|\(kind.rawValue)"
        if let last = lastNotice[key], now.timeIntervalSince(last) < Engine.noticeWindow, now >= last {
            heldNotices[key] = (agent, kind, (heldNotices[key]?.count ?? 0) + count)
            return
        }
        lastNotice[key] = now
        postNotice(agent, kind, count: count)
    }

    /// Sends the summary of notifications held back once their window is over.
    private func flushHeldNotices() {
        for (key, held) in heldNotices {
            if let last = lastNotice[key], now.timeIntervalSince(last) < Engine.noticeWindow, now >= last { continue }
            heldNotices[key] = nil
            lastNotice[key] = now
            if notifyAgents { postNotice(held.agent, held.kind, count: held.count) }
        }
    }

    private func postNotice(_ agent: String, _ kind: AgentEvent.Kind, count: Int) {
        let name = AgentIntegrations.displayName(agent)
        switch kind {
        case .done:
            if count > 1 { notify(tr("%@ finished %d tasks", name, count), tr("Your agents are done. AFK Pug will let the Mac sleep soon.")) }
            else { notify(tr("%@ finished", name), tr("Your agent is done. AFK Pug will let the Mac sleep soon.")) }
        case .failed:
            if count > 1 { notify(tr("%@ stopped with an error %d times", name, count), tr("Your agent hit an error or a usage limit.")) }
            else { notify(tr("%@ stopped with an error", name), tr("Your agent hit an error or a usage limit.")) }
        case .waiting:
            let body = lidClosed ? tr("Your agent is waiting for your input. If it stays idle, the Mac sleeps in about 15 minutes.")
                                 : tr("Your agent is waiting for your input.")
            if count > 1 { notify(tr("%@ needs you (%d requests)", name, count), body) }
            else { notify(tr("%@ needs you", name), body) }
        }
    }

    /// Lid edge bookkeeping for the music rule.
    private func lidChanged(_ closed: Bool) {
        if closed {
            closedAt = now
            musicAtClose = lastMusicHeard.map { now.timeIntervalSince($0) < 30 } ?? false
        } else {
            closedAt = nil
            musicAtClose = false
        }
    }

    /// The wall clock was set back: shift every stored time so timers keep their length.
    private func clockWentBack(by delta: TimeInterval) {
        func back(_ d: Date?) -> Date? { d.map { $0.addingTimeInterval(-delta) } }
        manualStart = back(manualStart)
        manualEnd = back(manualEnd)
        holdsEndedAt = back(holdsEndedAt)
        graceUntil = back(graceUntil)
        lastDisplayOff = lastDisplayOff.addingTimeInterval(-delta)
        lastMusicHeard = back(lastMusicHeard)
        closedAt = back(closedAt)
        acSince = back(acSince)
        coolSince = back(coolSince)
        for (pid, d) in procLastBusy { procLastBusy[pid] = d.addingTimeInterval(-delta) }
        for (pid, d) in procFirstSeen { procFirstSeen[pid] = d.addingTimeInterval(-delta) }
        if var s = openSummary { s = LidSummary(closedAt: s.closedAt.addingTimeInterval(-delta), openedAt: s.openedAt,
                                                startBattery: s.startBattery, endBattery: s.endBattery,
                                                peakThermal: s.peakThermal, agentsFinished: s.agentsFinished, hadBattery: s.hadBattery)
            openSummary = s }
    }

    /// Agents without hooks, found by process and CPU use. An agent whose hooks hold
    /// the Mac awake right now is skipped, and so are the processes seen meanwhile
    /// (until they exit or the hooks are disconnected): the hooks report that agent.
    private func scanProcesses(hookHolds: [AgentHold]) -> [AgentHold] {
        guard agentMode, detectOtherAgents else { return [] }
        let hooked = AgentIntegrations.hookedProcessNames(holds: hookHolds)
        // Disconnected hooks report nothing any more: process detection takes over.
        let active = Set(AgentIntegrations.all.filter { AgentIntegrations.hooksActive($0, connected: connected) }.flatMap(\.processNames))
        hookedProcs = hookedProcs.filter { active.contains($0.value) }
        // `ps` costs ~25 ms of CPU; every ~5 s is plenty given the 30 s linger below.
        if now.timeIntervalSince(lastProcScan) >= 5 || now < lastProcScan {
            lastProcScan = now
            let all = ProcessWatcher.scan()
            let live = Set(all.map(\.pid))
            hookedProcs = hookedProcs.filter { live.contains($0.key) }
            for agent in all where hooked.contains(agent.display) && active.contains(agent.display) { hookedProcs[agent.pid] = agent.display }
            let found = all.filter { !hooked.contains($0.display) && hookedProcs[$0.pid] == nil }
            // A released process stays ignored until it exits (not just until it idles).
            ignoredProcs.formIntersection(live)
            for agent in found where agent.busy && !ignoredProcs.contains(agent.pid) {
                procLastBusy[agent.pid] = now
                procNames[agent.pid] = agent.display
                if procFirstSeen[agent.pid] == nil { procFirstSeen[agent.pid] = now }
            }
        }
        // Count as working for 30 s after the last busy sample, so short pauses don't flap;
        // a hook taking over ends the process hold right away.
        for (pid, last) in procLastBusy where now.timeIntervalSince(last) > 30 || hookedProcs[pid] != nil
            || procNames[pid].map(hooked.contains) == true {
            procLastBusy[pid] = nil
            procFirstSeen[pid] = nil
            procNames[pid] = nil
        }
        return procLastBusy.keys.sorted().map { pid in
            AgentHold(id: "proc-\(pid)", agent: procNames[pid] ?? "agent", started: procFirstSeen[pid] ?? now, expires: nil, reason: nil)
        }
    }

    private func updateGuards() {
        acSince = battery.onAC ? (acSince ?? now) : nil
        coolSince = thermal.rawValue <= ProcessInfo.ThermalState.fair.rawValue ? (coolSince ?? now) : nil
        if battery.onAC || battery.percent > batteryFloor + Engine.batteryWarningMargin + 1 { lowBatteryWarned = false }
        if let current = trip {
            switch current {
            case .battery:
                // A loose charger must not flap the trip (and spam notifications).
                let acSteady = acSince.map { now.timeIntervalSince($0) >= 30 } ?? false
                if acSteady || battery.percent > batteryFloor + 5 { trip = nil }
            case .thermal:
                // Stay off until the Mac has been cool for 5 minutes.
                if let since = coolSince, now.timeIntervalSince(since) >= Engine.coolDown { trip = nil }
            }
            return
        }
        guard isActive || manualOn || !holds.isEmpty || triggerReason != nil else { return }
        if battery.hasBattery, !battery.onAC, battery.percent <= batteryFloor {
            trip = .battery(battery.percent)
            manualOn = false
            log("battery.25percent", tr("Battery at %d%%. Letting the Mac sleep", battery.percent))
            if now.timeIntervalSince(lastBatteryNotice) >= 600 || now < lastBatteryNotice {
                lastBatteryNotice = now
                notify(tr("Battery low"), tr("AFK Pug stopped at %d%% so your Mac can sleep safely.", battery.percent))
            }
        } else if thermal == .critical {
            trip = .thermal
            manualOn = false
            log("thermometer.high", tr("Mac too hot. Letting it sleep"))
            if now.timeIntervalSince(lastThermalNotice) >= 600 || now < lastThermalNotice {
                lastThermalNotice = now
                notify(tr("Too hot"), tr("AFK Pug stopped so your Mac can cool down."))
            }
        } else if battery.hasBattery, !battery.onAC, battery.percent <= batteryFloor + Engine.batteryWarningMargin, !lowBatteryWarned {
            lowBatteryWarned = true
            log("battery.25percent", tr("Battery at %d%%. AFK Pug stops at %d%%", battery.percent, batteryFloor))
            notify(tr("Battery getting low"), tr("AFK Pug stops at %d%%. Plug in to keep going.", batteryFloor))
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
        if !lidEngaged, lidClosed, isActive, lastWantLid, lidOverrideOn { engageLid() }
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
        if lowPowerOnClose, lowPowerChangedSource == nil, setupDone,
           thermal == .serious || (battery.hasBattery && !battery.onAC) { enableLowPower() }
    }

    private func handleEvents(_ events: [AgentEvent]) {
        // The same event written twice (parallel hooks, Cursor running Claude's hooks
        // too) counts once per agent + session + kind.
        var seen = Set<String>()
        for event in events where seen.insert("\(event.agent)|\(event.session ?? "")|\(event.kind.rawValue)").inserted {
            let name = AgentIntegrations.displayName(event.agent)
            switch event.kind {
            case .done:
                // Confirmed later: a Stop hook may continue the turn right away.
                if let id = event.holdId, pendingDone.contains(where: { $0.holdId == id }) { continue }
                pendingDone.append((agent: event.agent, holdId: event.holdId, at: now))
            case .failed:
                log("exclamationmark.triangle.fill", tr("%@ stopped with an error", name))
                agentNotice(event.agent, .failed)
            case .waiting:
                log("hand.raised.fill", tr("%@ needs you", name))
                agentNotice(event.agent, .waiting)
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
            // On failure the flag stays, so the watchdog / next launch retries.
            if PowerControl.setLowPower(false, source: source) { try? FileManager.default.removeItem(at: Paths.lowPowerFlag) }
            lowPowerChangedSource = nil
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

    /// "1:45" or "0:05", rounded up, so it never reads 0:00 while time is left.
    static func hoursMinutes(_ t: TimeInterval) -> String {
        let total = Int((max(0, t) / 60).rounded(.up))
        return String(format: "%d:%02d", total / 60, total % 60)
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
        if s >= 3600 { return (s % 3600) / 60 == 0 ? tr("%dh", s / 3600) : tr("%dh %dm", s / 3600, (s % 3600) / 60) }
        return s >= 60 ? tr("%dm %ds", s / 60, s % 60) : tr("%ds", s)
    }

    static func duration(_ t: TimeInterval) -> String {
        let m = Int(t / 60)
        if m < 1 { return tr("under a minute") }
        if m < 60 { return tr("%dm", m) }
        return m % 60 == 0 ? tr("%dh", m / 60) : tr("%dh %dm", m / 60, m % 60)
    }
}
