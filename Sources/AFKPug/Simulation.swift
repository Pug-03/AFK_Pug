import Foundation

/// Headless scenario runner for the lid / session state machine.
///
///     AFKPUG_SIM=1 AFKPug --simulate all          # every scenario, one process each
///     AFKPUG_SIM=1 AFKPug --simulate manual       # a single scenario
///
/// Refuses to run unless `AFKPUG_SIM=1`, so nothing real is ever touched: all
/// power / audio / lock / signal actions go to `<sim dir>/actions.log` (see `Sim`).
@MainActor
enum Simulation {
    static let scenarios: [(name: String, about: String)] = [
        ("manual", "(a) Go AFK, close lid, open lid, stop"),
        ("agent", "(b) agent hold, close lid, hold removed: grace then sleepnow"),
        ("battery", "(c) battery drops below floor while closed"),
        ("thermal", "(d) serious then critical heat while closed"),
        ("music", "(e) music playing, close lid: no mute; music stops: sleep"),
        ("music-late", "(e2) music starts after the lid closed: sound comes back"),
        ("shutdown", "(f) app quits while closed with everything engaged"),
        ("crash", "(f2) app dies while closed (no shutdown) ..."),
        ("recovery", "(f2) ... next launch restores mute, low power, chat apps, lid sleep"),
        ("closed-start", "(g) session starts while the lid is already closed"),
        ("closed-busy", "(g3) flag says closed but someone is typing: no lock until a real close"),
        ("docked", "(g2) lid closed with an external display: no lock, no sleepnow"),
        ("grace0", "(h) graceMinutes = 0"),
        ("override-flip", "macOS flips disablesleep back while closed"),
        ("unplug", "lid only on power: charger unplugged while closed"),
        ("open-race", "work ends on the same tick the lid opens"),
        ("sudo-broken", "sudoers rule disappears: no sudo every 2 s"),
        ("procs", "process detection: no false positives, release sticks"),
        // Regression scenarios for the review fixes
        ("claude-hooks", "[1,12] hooks install/uninstall idempotently through a symlink; touch/wait/staleness"),
        ("chat-call", "[2] a chat app in a call is never paused, so the call keeps the Mac awake"),
        ("lid-stale-active", "[3] stale clamshell Yes while the user is active: never locks"),
        ("lid-panel-wake", "[3] display wakes under the lid without input: no flapping"),
        ("lid-hid-open", "[3] HID input under a stale Yes opens; a real close message closes again"),
        ("monitor-debounce", "[3] docked: a monitor blip or CG error doesn't lock; staying gone does"),
        ("release-fail", "[4] failed disablesleep 0 is retried until it sticks"),
        ("lowpower-source", "[5] Low Power Mode only on the current power source, restored exactly"),
        ("cli-script", "[6,10] afkpug run doesn't hold stdout; hold --reason strips control chars"),
        ("settings-errors", "[7] Claude / MCP connect errors shown separately, cleared on retry"),
        ("agentmode-off", "[8] Agent mode off: holds drive no headline, grace or battery guard"),
        ("hotkey-trip", "[9] hotkey can't restart a session while a guard trip is set"),
        ("mcp-clamp", "[11] MCP minutes 1e300 / negative / NaN are clamped, no trap"),
        ("stale-events", "events from while the app wasn't running don't fire on launch"),
        ("procs-matrix", "agent process matching: real installs vs. look-alikes"),
        ("uninstall", "uninstall restores everything and removes every trace"),
        ("sleep-now", "Sleep now ends grace / manual and snoozes music and charger until they go away"),
        ("url-scheme", "afkpug:// commands"),
        ("preview-th", "[13] Thai preview after 85 min closed renders, busy Claude hold survives"),
        ("codex-hooks", "Codex ~/.codex/hooks.json: install/upgrade/uninstall, real hook commands, no double hold"),
        ("gemini-hooks", "Gemini CLI settings.json hooks: install/upgrade/uninstall, JSONC refused, real hook commands"),
        ("cursor-hooks", "Cursor hooks.json: JSON replies, stop status, Claude hooks run by Cursor, script missing"),
        ("claude-plugin", "Claude Code plugin installed: no settings.json hooks; repo plugin/ commands work"),
        ("usage-limit", "Claude usage limit: hold until the reset (formats, cap, default), auto-resume, errors release"),
    ]
    /// Old names of the review proofs, kept as aliases.
    static let reviewScenarios = ["review-chat-call", "review-hotkey-trip", "review-agentmode-off", "review-preview", "review-release-fail",
                                  "preview-grace", "preview-states"]

    static func main(_ args: [String]) -> Int32 {
        setvbuf(stdout, nil, _IOLBF, 0)
        guard Sim.enabled else {
            print("Refusing to simulate without AFKPUG_SIM=1 (it would touch real power state).")
            return 2
        }
        let name = args.first ?? "all"
        if name == "all" { return runAll() }
        if name == "stress" { return runAll(stressScenarios) }
        guard scenarios.contains(where: { $0.name == name }) || reviewScenarios.contains(name)
                || stressScenarios.contains(where: { $0.name == name }) || name.hasPrefix("stress-crashchild-") else {
            print("Unknown scenario \(name). Known: all, " + scenarios.map(\.name).joined(separator: ", "))
            return 2
        }
        return Runner(name: name).run()
    }

    /// Each scenario runs in a fresh process, since Engine is a singleton.
    private static func runAll(_ only: [(name: String, about: String)]? = nil) -> Int32 {
        let list = only ?? scenarios
        var failed: [String] = []
        for (name, about) in list {
            print("\n=== \(name): \(about)")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
            process.arguments = ["--simulate", name]
            var env = ProcessInfo.processInfo.environment
            env["AFKPUG_SIM"] = "1"
            env["AFKPUG_SIM_DIR"] = Sim.dir.path
            process.environment = env
            do { try process.run() } catch { print("could not launch: \(error)"); return 2 }
            process.waitUntilExit()
            if process.terminationStatus != 0 { failed.append(name) }
        }
        print("\n" + (failed.isEmpty ? "ALL \(list.count) SCENARIOS PASSED" : "FAILED: " + failed.joined(separator: ", ")))
        return failed.isEmpty ? 0 : 1
    }
}

@MainActor
private final class Runner {
    let name: String
    var failures = 0
    var logOffset = 0
    var engine: Engine { Engine.shared }

    init(name: String) { self.name = name }

    // Stress harness state (see the Stress extension at the end of the file)
    /// Ground truth of the simulated world, independent of what the raw flag says.
    var truthOpen = true
    var truthDocked = false
    /// Repetition is the stimulus itself (flapping), so don't call it spam.
    var allowRepeat = false
    var recentTicks: [Set<String>] = []
    var notifies: [(t: TimeInterval, title: String)] = []
    var lastDisplayOffAt: TimeInterval = -1000
    var baseline: [String: String] = [:]
    var reported = Set<String>()
    var printLines = true

    // MARK: Sandbox

    static let sensorFiles = ["lid", "lid-event", "display", "battery", "thermal", "audio", "apps", "procs", "setup", "claude",
                              "pmset-disablesleep", "pmset-lowpowermode-b", "pmset-lowpowermode-c", "muted", "idle", "actions.log"]

    func resetSandbox() {
        let fm = FileManager.default
        for file in Self.sensorFiles { try? fm.removeItem(at: Sim.dir.appendingPathComponent(file)) }
        try? fm.removeItem(at: Paths.root)
        UserDefaults.standard.removePersistentDomain(forName: "com.pug03.afkpug.sim")
        Paths.ensure()
        Sim.set("lid", "open")
        Sim.set("display", "builtin")
        Sim.set("battery", "80 battery")
        Sim.set("thermal", "nominal")
        Sim.set("audio", "silent")
        Sim.set("setup", "yes")
        Sim.set("idle", "600")
        Sim.set("muted", "0")
        Sim.set("pmset-disablesleep", "0")
        Sim.set("pmset-lowpowermode-b", "0")
        Sim.set("pmset-lowpowermode-c", "0")
    }

    /// Settings are written before Engine.shared exists, so no didSet ticks fire.
    func configure(_ values: [String: Any] = [:]) {
        let base: [String: Any] = [
            "agentMode": true, "lidMode": true, "selectedMinutes": 120, "batteryFloor": 15,
            "displayOffOnClose": true, "muteOnClose": true, "lowPowerOnClose": true, "lidOnlyOnPower": false,
            "notifyAgents": true, "graceMinutes": 2, "detectOtherAgents": true, "pauseChatApps": true,
            "lockOnClose": true, "hotkeyEnabled": false, "phoneTopic": "", "autoOnPower": false,
            "autoApps": "", "keepMusic": true,
        ]
        for (key, value) in base.merging(values, uniquingKeysWith: { $1 }) { Engine.store.set(value, forKey: key) }
    }

    func boot() {
        Sim.headless = true
        engine.boot()
        logOffset = readLog().count
    }

    // MARK: Steps

    func readLog() -> [String] {
        ((try? String(contentsOf: Sim.actionLog, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    /// Runs `ticks` engine ticks `every` seconds apart after `change`, prints the
    /// actions logged, and checks them: `expect` in order, `forbid` nowhere.
    func step(_ label: String, ticks: Int = 1, every: TimeInterval = 2, expect: [String] = [], forbid: [String] = [],
              _ change: () -> Void = {}) {
        Sim.record("--- \(label)")
        change()
        for _ in 0..<ticks {
            Sim.clockOffset += every
            engine.tick()
        }
        let lines = Array(readLog().dropFirst(logOffset))
        logOffset += lines.count
        for line in lines { print("  " + line) }
        var index = 0
        var missing: [String] = []
        for want in expect {
            if let hit = lines[index...].firstIndex(where: { $0.contains(want) }) { index = hit + 1 } else { missing.append(want) }
        }
        let bad = forbid.filter { f in lines.contains { $0.contains(f) } }
        if !missing.isEmpty { fail("missing (in order): \(missing)") }
        if !bad.isEmpty { fail("unexpected: \(bad)") }
    }

    func check(_ condition: Bool, _ what: String) {
        if condition { print("  ok: \(what)") } else { fail(what) }
    }

    func fail(_ message: String) {
        failures += 1
        print("  FAIL: \(message)")
    }

    func hold(_ id: String, agent: String = "claude", expires: TimeInterval = 0, pid: Int32 = 0) {
        let now = Clock.now().timeIntervalSince1970
        let json = "{\"agent\":\"\(agent)\",\"started\":\(Int(now)),\"expires\":\(expires > 0 ? Int(now + expires) : 0),\"pid\":\(pid)}"
        let url = Paths.holds.appendingPathComponent(id)
        try? json.write(to: url, atomically: true, encoding: .utf8)
        age(id, by: 0)
    }

    /// Sets a hold's last-touched time to `seconds` before the (shifted) clock.
    func age(_ id: String, by seconds: TimeInterval) {
        try? FileManager.default.setAttributes([.modificationDate: Clock.now().addingTimeInterval(-seconds)],
                                               ofItemAtPath: Paths.holds.appendingPathComponent(id).path)
    }

    /// Runs one of the generated shell scripts with HOME pointing at the sandbox.
    @discardableResult
    func script(_ url: URL, _ args: [String], stdin: String = "") -> (status: Int32, output: String, seconds: Double) {
        sh([url.path] + args, stdin: stdin)
    }

    /// Runs a hook command line exactly as an agent would (`sh -c`), HOME in the sandbox.
    @discardableResult
    func shell(_ command: String, stdin: String = "") -> (status: Int32, output: String, seconds: Double) {
        sh(["-c", command], stdin: stdin)
    }

    private func sh(_ arguments: [String], stdin: String) -> (status: Int32, output: String, seconds: Double) {
        let home = Sim.dir.appendingPathComponent("home")
        let link = home.appendingPathComponent(".afkpug")
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) == nil {
            try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            try? FileManager.default.createSymbolicLink(at: link, withDestinationURL: Paths.root)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = home.path
        process.environment = env
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output
        let started = Date()
        do { try process.run() } catch { fail("could not run \(arguments)"); return (-1, "", 0) }
        input.fileHandleForWriting.write(Data(stdin.utf8))
        try? input.fileHandleForWriting.close()
        // Reads until every writer (including background children) closes stdout.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let seconds = Date().timeIntervalSince(started)
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self), seconds)
    }

    func dropHold(_ id: String, event: String? = "done") {
        try? FileManager.default.removeItem(at: Paths.holds.appendingPathComponent(id))
        if let event { FileManager.default.createFile(atPath: Paths.events.appendingPathComponent("\(Int(Clock.now().timeIntervalSince1970))1-claude-\(event)").path, contents: Data()) }
    }

    /// Nothing we changed is left behind.
    func checkRestored(lidOverride: Bool = false) {
        let fm = FileManager.default
        check(Sim.value("muted") == "0", "audio unmuted")
        check(Sim.value("pmset-lowpowermode-b") == "0" && Sim.value("pmset-lowpowermode-c") == "0", "low power mode off")
        check(Sim.value("pmset-disablesleep") == (lidOverride ? "1" : "0"), "disablesleep \(lidOverride ? 1 : 0)")
        check(!fm.fileExists(atPath: ChatPauser.file.path), "no chat apps left paused")
        check(!fm.fileExists(atPath: Paths.muteFlag.path) && !fm.fileExists(atPath: Paths.lowPowerFlag.path), "no restore flags left")
        check(!engine.lidEngaged, "lid actions disengaged")
    }

    static let closeActions = ["log: Lid closed. Still working", "lock screen", "pmset displaysleepnow", "SIGSTOP chat apps",
                               "play sound Tink", "mute", "sudo pmset -b lowpowermode 1"]
    static let restoreActions = ["SIGCONT chat apps", "unmute", "sudo pmset -b lowpowermode 0"]

    // MARK: Scenarios

    func run() -> Int32 {
        if name != "recovery", !name.hasPrefix("stress-crashchild-") { resetSandbox() }
        Sim.record("=== scenario \(name)")
        switch name {
        case "manual": manual()
        case "agent": agent()
        case "battery": batteryGuard()
        case "thermal": thermalGuard()
        case "music": music()
        case "music-late": musicLate()
        case "shutdown": shutdown()
        case "crash": crash()
        case "recovery": recovery()
        case "closed-start": closedStart()
        case "closed-busy": closedBusy()
        case "docked": docked()
        case "grace0": grace0()
        case "override-flip": overrideFlip()
        case "unplug": unplug()
        case "open-race": openRace()
        case "sudo-broken": sudoBroken()
        case "procs": procs()
        case "claude-hooks": claudeHooks()
        case "chat-call", "review-chat-call": chatCall()
        case "lid-stale-active": lidStaleActive()
        case "lid-panel-wake": lidPanelWake()
        case "lid-hid-open": lidHidOpen()
        case "monitor-debounce": monitorDebounce()
        case "release-fail", "review-release-fail": releaseFail()
        case "lowpower-source": lowPowerSource()
        case "cli-script": cliScript()
        case "settings-errors": settingsErrors()
        case "agentmode-off", "review-agentmode-off": agentModeOff()
        case "hotkey-trip", "review-hotkey-trip": hotkeyTrip()
        case "mcp-clamp": mcpClamp()
        case "stale-events": staleEvents()
        case "procs-matrix": procsMatrix()
        case "uninstall": uninstallAll()
        case "sleep-now": sleepNowScenario()
        case "url-scheme": urlScheme()
        case "preview-th", "review-preview": previewTh()
        case "preview-grace": previewGrace()
        case "codex-hooks": codexHooks()
        case "gemini-hooks": geminiHooks()
        case "cursor-hooks": cursorHooks()
        case "claude-plugin": claudePlugin()
        case "usage-limit": usageLimit()
        case "preview-states": previewStates()
        default:
            if name.hasPrefix("stress-") { runStress() } else { fail("no scenario") }
        }
        if name != "crash" { UserDefaults.standard.removePersistentDomain(forName: "com.pug03.afkpug.sim") }
        print(failures == 0 ? "  PASS" : "  FAILED (\(failures))")
        return failures == 0 ? 0 : 1
    }

    func manual() {
        configure(); boot()
        step("Go AFK", expect: ["log: Awake for 2h", "idle assertion ON", "sudo pmset -a disablesleep 1"],
             forbid: ["lock screen", "pmset sleepnow"]) { engine.start() }
        step("close lid", expect: Self.closeActions, forbid: ["pmset sleepnow", "disablesleep 0"]) { Sim.set("lid", "closed") }
        step("40 s with the lid closed", ticks: 20, expect: ["pmset displaysleepnow"],
             forbid: ["pmset sleepnow", "disablesleep", "lock screen", "SIGSTOP"])
        step("open lid", expect: Self.restoreActions + ["notify: While you were away", "log: Welcome back"],
             forbid: ["pmset sleepnow", "idle assertion OFF", "disablesleep 0"]) { Sim.set("lid", "open") }
        step("Stop", expect: ["idle assertion OFF", "sudo pmset -a disablesleep 0"], forbid: ["pmset sleepnow"]) { engine.stop() }
        checkRestored()
    }

    func agent() {
        configure(); boot()
        step("Claude hold appears", expect: ["log: Claude Code started working", "idle assertion ON", "disablesleep 1"]) { hold("claude-s1") }
        step("close lid", expect: Self.closeActions, forbid: ["pmset sleepnow"]) { Sim.set("lid", "closed") }
        step("hold removed (Stop hook): grace starts", ticks: 30,
             expect: ["log: Claude Code finished"], forbid: ["pmset sleepnow", "disablesleep 0", "unmute"]) { dropHold("claude-s1") }
        check(engine.graceUntil != nil && engine.isActive, "still awake during the 2 min grace")
        step("grace runs out", ticks: 31, expect: Self.restoreActions + ["notify: While you were away", "idle assertion OFF", "disablesleep 0", "pmset sleepnow"])
        checkRestored()
    }

    func batteryGuard() {
        configure(); boot()
        step("Go AFK on battery", expect: ["disablesleep 1"]) { engine.start() }
        step("close lid", expect: Self.closeActions) { Sim.set("lid", "closed") }
        step("battery 14%", expect: ["log: Battery at 14%", "notify: Battery low"] + Self.restoreActions
             + ["idle assertion OFF", "disablesleep 0", "pmset sleepnow"]) { Sim.set("battery", "14 battery") }
        check(engine.trip == .battery(14) && !engine.manualOn, "guard tripped, manual session ended")
        step("still closed, a few ticks", ticks: 5, forbid: ["disablesleep 1", "lock screen", "idle assertion ON"])
        step("open lid", forbid: ["unmute", "lowpowermode", "pmset sleepnow"]) { Sim.set("lid", "open") }
        checkRestored()
    }

    func thermalGuard() {
        configure(); boot()
        step("Go AFK on the charger", expect: ["disablesleep 1"]) { Sim.set("battery", "90 ac"); engine.start() }
        step("close lid (on AC: no low power yet)", expect: ["lock screen", "mute"], forbid: ["lowpowermode"]) { Sim.set("lid", "closed") }
        step("thermal serious (on AC: charger source only)", expect: ["sudo pmset -c lowpowermode 1"], forbid: ["pmset sleepnow", "-b lowpowermode"]) { Sim.set("thermal", "serious") }
        step("thermal critical", expect: ["log: Mac too hot", "notify: Too hot", "SIGCONT chat apps", "unmute", "sudo pmset -c lowpowermode 0",
                                          "idle assertion OFF", "disablesleep 0", "pmset sleepnow"]) { Sim.set("thermal", "critical") }
        check(engine.trip == .thermal, "thermal guard tripped")
        step("cools to fair: stays tripped for 5 min", ticks: 10, forbid: ["disablesleep 1"]) { Sim.set("thermal", "fair") }
        check(engine.trip == .thermal, "trip holds while cooling")
        step("cool for 5 min: trip clears, nothing restarts (manual was stopped)", ticks: 141, forbid: ["disablesleep 1", "notify: Too hot"])
        check(engine.trip == nil, "trip cleared")
        checkRestored()
    }

    func music() {
        configure(); boot()
        step("music playing", expect: ["idle assertion ON", "disablesleep 1"]) { Sim.set("audio", "playing") }
        check(engine.triggerReason == "music playing", "trigger = music playing")
        step("close lid", expect: ["lock screen", "pmset displaysleepnow", "SIGSTOP chat apps", "sudo pmset -b lowpowermode 1"],
             forbid: ["mute", "Tink", "pmset sleepnow"]) { Sim.set("lid", "closed") }
        step("10 min of music", ticks: 300, forbid: ["mute", "pmset sleepnow", "disablesleep 0"])
        step("music stops (30 s gap allowance)", ticks: 16, expect: ["SIGCONT chat apps", "sudo pmset -b lowpowermode 0", "idle assertion OFF", "disablesleep 0", "pmset sleepnow"],
             forbid: ["unmute"]) { Sim.set("audio", "silent") }
        checkRestored()
    }

    func musicLate() {
        configure(); boot()
        step("Go AFK", expect: ["disablesleep 1"]) { engine.start() }
        step("close lid (silent: muted)", expect: ["play sound Tink", "mute"]) { Sim.set("lid", "closed") }
        step("music starts under the lid", expect: ["unmute"], forbid: ["pmset sleepnow"]) { Sim.set("audio", "playing") }
        step("music stops: manual session keeps it awake", ticks: 3, forbid: ["pmset sleepnow", "disablesleep 0"]) { Sim.set("audio", "silent") }
        step("Stop (hotkey) with the lid closed", expect: ["SIGCONT chat apps", "lowpowermode 0", "disablesleep 0", "pmset sleepnow"],
             forbid: ["unmute"]) { engine.stop() }
        checkRestored()
    }

    func shutdown() {
        configure(); boot()
        step("Go AFK + agent hold", expect: ["disablesleep 1"]) { engine.start(); hold("claude-s1") }
        step("close lid", expect: Self.closeActions) { Sim.set("lid", "closed") }
        step("app quits (applicationWillTerminate)", ticks: 0, expect: Self.restoreActions + ["disablesleep 0", "idle assertion OFF"]) {
            engine.shutdown()
        }
        checkRestored()
    }

    func crash() {
        configure(); boot()
        step("Go AFK", expect: ["disablesleep 1"]) { engine.start() }
        step("close lid", expect: Self.closeActions) { Sim.set("lid", "closed") }
        print("  (process exits here without shutdown, like a crash)")
        check(FileManager.default.fileExists(atPath: Paths.lidFlag.path) && FileManager.default.fileExists(atPath: Paths.muteFlag.path)
              && FileManager.default.fileExists(atPath: Paths.lowPowerFlag.path), "restore flags on disk")
    }

    func recovery() {
        Sim.set("lid", "open")
        configure(); logOffset = readLog().count
        step("relaunch after the crash", ticks: 0, expect: ["disablesleep 0", "log: Restored normal lid sleep", "SIGCONT chat apps",
                                                             "lowpowermode 0", "unmute"]) {
            Sim.headless = true
            engine.boot()
        }
        checkRestored()
    }

    func closedStart() {
        Sim.set("lid", "closed")
        configure(); boot()
        step("idle, lid already closed", ticks: 3, forbid: ["lock screen", "disablesleep", "pmset sleepnow"])
        step("agent hold appears (e.g. dark wake / remote)", expect: ["disablesleep 1"] + Self.closeActions) { hold("claude-s1") }
        step("hold removed + grace", ticks: 62, expect: Self.restoreActions + ["disablesleep 0", "pmset sleepnow"]) { dropHold("claude-s1") }
        checkRestored()
    }

    /// The flag reads Yes but someone is typing: it's stale. Only a real
    /// clamshell change (IOKit message) closes it afterwards.
    func closedBusy() {
        Sim.set("lid", "closed"); Sim.set("idle", "1")
        configure(); boot()
        step("Go AFK while the user is typing", ticks: 5, expect: ["disablesleep 1"], forbid: ["lock screen", "mute", "SIGSTOP"]) { engine.start() }
        step("user stops typing and reads (idle 90 s), flag still Yes", ticks: 30, forbid: ["lock screen", "mute", "SIGSTOP", "pmset sleepnow"]) { Sim.set("idle", "90") }
        step("real close: IOKit clamshell message", expect: Self.closeActions) { Sim.set("lid-event", "closed") }
        step("Stop", expect: Self.restoreActions + ["pmset sleepnow"]) { engine.stop() }
        checkRestored()
    }

    func docked() {
        Sim.set("lid", "closed"); Sim.set("display", "external"); Sim.set("battery", "100 ac")
        configure(); boot()
        step("Go AFK while docked in clamshell", expect: ["disablesleep 1"], forbid: ["lock screen", "mute", "SIGSTOP"]) { engine.start() }
        step("Stop", expect: ["disablesleep 0"], forbid: ["pmset sleepnow"]) { engine.stop() }
        step("agent finishes while docked", ticks: 62, forbid: ["pmset sleepnow", "lock screen"]) { hold("codex-1", agent: "codex") }
        step("hold removed", ticks: 62, expect: ["idle assertion OFF"], forbid: ["pmset sleepnow", "lock screen"]) { dropHold("codex-1", event: nil) }
        step("monitor unplugged with lid still closed", ticks: 2, forbid: ["pmset sleepnow", "lock screen"]) { Sim.set("display", "builtin") }
        checkRestored()
    }

    func grace0() {
        configure(["graceMinutes": 0]); boot()
        step("hold appears", expect: ["disablesleep 1"]) { hold("claude-s1") }
        step("close lid", expect: Self.closeActions) { Sim.set("lid", "closed") }
        step("hold removed: sleeps on the same tick", expect: Self.restoreActions + ["disablesleep 0", "pmset sleepnow"]) { dropHold("claude-s1") }
        check(!engine.isActive, "inactive immediately")
        checkRestored()
    }

    func overrideFlip() {
        configure(); boot()
        step("Go AFK + close", expect: ["disablesleep 1", "lock screen"]) { engine.start(); Sim.set("lid", "closed") }
        step("macOS resets SleepDisabled to 0", ticks: 4, expect: ["sudo pmset -a disablesleep 1"],
             forbid: ["pmset sleepnow", "unmute", "lock screen"]) { Sim.set("pmset-disablesleep", "0") }
        check(Sim.value("pmset-disablesleep") == "1", "override re-applied")
        step("10 s steady: no extra sudo calls", ticks: 5, forbid: ["sudo pmset"])
    }

    func unplug() {
        configure(["lidOnlyOnPower": true]); boot()
        step("Go AFK on the charger", expect: ["disablesleep 1"]) { Sim.set("battery", "90 ac"); engine.start() }
        step("close lid (on AC: no low power)", expect: ["lock screen", "mute"], forbid: ["lowpowermode"]) { Sim.set("lid", "closed") }
        step("charger unplugged", expect: ["SIGCONT chat apps", "unmute", "disablesleep 0", "pmset sleepnow"]) { Sim.set("battery", "89 battery") }
        check(engine.isActive && !engine.lidOverrideOn, "manual session still on, override off")
        step("open lid", forbid: ["unmute", "pmset sleepnow"]) { Sim.set("lid", "open") }
        checkRestored()
        engine.stop()
    }

    func openRace() {
        configure(["graceMinutes": 0]); boot()
        step("hold + close", expect: ["disablesleep 1", "lock screen"]) { hold("claude-s1"); Sim.set("lid", "closed") }
        step("lid opens on the same tick the agent stops", expect: Self.restoreActions + ["disablesleep 0"], forbid: ["pmset sleepnow"]) {
            dropHold("claude-s1"); Sim.set("lid", "open")
        }
        checkRestored()
    }

    func sudoBroken() {
        configure(); boot()
        step("Go AFK + close", expect: ["disablesleep 1", "lock screen"]) { engine.start(); Sim.set("lid", "closed") }
        step("rule removed and macOS resets SleepDisabled", ticks: 30, expect: ["FAILED", "unmute", "pmset sleepnow"]) {
            Sim.set("setup", "no"); Sim.set("pmset-disablesleep", "0")
        }
        let attempts = readLog().filter { $0.contains("disablesleep 1") && $0.contains("FAILED") }.count
        check(attempts == 1, "one failed sudo attempt in 60 s, not 30 (got \(attempts))")
        check(!engine.setupDone, "setup marked as needed again")
        engine.stop()
    }

    func procs() {
        configure(); boot()
        let ps = """
          100     1   0.0 /sbin/launchd
          200   100   0.0 /bin/zsh -l
          300   200  50.0 grep amp
          301   200  50.0 vim gemini
          302   200  50.0 /usr/bin/less /tmp/goose
          303   200  50.0 git -C codex status
          400   200   0.5 node /opt/homebrew/bin/codex
          401   400  12.0 /opt/homebrew/lib/node_modules/@openai/codex/vendor/aarch64-apple-darwin/codex/codex
          500   200   0.0 /usr/local/bin/aider --model x
          600   200   9.0 /opt/homebrew/bin/python3.12 /Users/me/.local/bin/aider
        """
        step("ps sample (scanned every ~5 s)", ticks: 3, expect: ["log: Codex started working", "log: Aider started working", "disablesleep 1"]) { Sim.set("procs", ps) }
        let names = engine.holds.map(\.agent).sorted()
        check(names == ["Aider", "Codex"], "only real agents detected (got \(names))")
        if let codex = engine.holds.first(where: { $0.agent == "Codex" }) {
            step("user releases Codex", forbid: ["Codex started working"]) { engine.release(codex) }
            check(!engine.holds.contains { $0.agent == "Codex" }, "Codex hold gone right away")
            step("Codex still busy for 2 min: stays released", ticks: 60, forbid: ["Codex started working"])
            check(!engine.holds.contains { $0.agent == "Codex" }, "release still honoured")
        }
    }

    // MARK: Regression scenarios (review fixes)

    /// [1] Hooks re-arm the hold on every tool call; Notification keeps it; a turn
    /// that ends without Stop (Esc) expires 15 min after the last touch, unless the
    /// owner's process tree is busy (one long tool call). [12] settings.json symlink.
    func claudeHooks() {
        configure(); boot()
        let fm = FileManager.default
        let target = Paths.root.appendingPathComponent("dotfiles/claude-settings.json")
        try? fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? #"{"model":"x","hooks":{"Stop":[{"hooks":[{"type":"command","command":"other-tool"}]}]}}"#.write(to: target, atomically: true, encoding: .utf8)
        try? fm.createDirectory(at: ClaudeHooks.settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.createSymbolicLink(at: ClaudeHooks.settingsURL, withDestinationURL: target)

        func commands() -> [String: [String]] {
            let json = (try? Data(contentsOf: target)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            let hooks = json["hooks"] as? [String: Any] ?? [:]
            return hooks.mapValues { (($0 as? [[String: Any]]) ?? []).flatMap { $0["hooks"] as? [[String: Any]] ?? [] }.compactMap { $0["command"] as? String } }
        }
        do { try ClaudeHooks.install(); try ClaudeHooks.install() } catch { fail("install threw \(error)") }
        let installed = commands()
        check((try? fm.destinationOfSymbolicLink(atPath: ClaudeHooks.settingsURL.path)) != nil, "settings.json is still a symlink")
        for (event, action) in ClaudeHooks.events {
            let ours = (installed[event] ?? []).filter { $0.contains(ClaudeHooks.marker) }
            check(ours.count == 1 && ours[0].contains(" \(action) claude"), "\(event) -> \(action), exactly once (got \(ours))")
        }
        check(installed["Stop"]?.contains("other-tool") == true, "other hooks kept")
        check(!ClaudeHooks.needsUpgrade(), "no upgrade needed after install")
        do { try ClaudeHooks.uninstall(); try ClaudeHooks.uninstall() } catch { fail("uninstall threw \(error)") }
        let removed = commands()
        check(!removed.values.joined().contains { $0.contains(ClaudeHooks.marker) }, "uninstall removes every event (incl. PreToolUse/PostToolUse)")
        check(removed["Stop"] == ["other-tool"] && (try? String(contentsOf: target, encoding: .utf8))?.contains("\"model\"") == true, "uninstall keeps the rest")

        let me = getpid()
        let idle = "  \(me)     1   0.4 /usr/local/bin/claude\n"
        let busy = idle + "  9001 \(me)  85.0 swift-build -c release\n"
        let input = #"{"session_id":"s1"}"#
        let holdURL = Paths.holds.appendingPathComponent("claude-s1")
        Sim.set("procs", idle)
        step("UserPromptSubmit", expect: ["log: Claude Code started working", "disablesleep 1"]) { script(Paths.hookScript, ["start", "claude"], stdin: input) }
        step("close lid", expect: Self.closeActions) { Sim.set("lid", "closed") }
        step("Notification (permission prompt): waiting event, hold kept", expect: ["notify: Claude Code needs you"], forbid: ["finished", "unmute"]) {
            script(Paths.hookScript, ["wait", "claude"], stdin: input)
        }
        check(fm.fileExists(atPath: holdURL.path), "hold survives the Notification hook")
        step("approved: tools run, PostToolUse touches the hold 14 min later", ticks: 3, forbid: ["unmute", "pmset sleepnow"]) {
            age("claude-s1", by: 14 * 60)
            script(Paths.hookScript, ["touch", "claude"], stdin: input)
            check(Date().timeIntervalSince((try? holdURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) < 5, "touch re-armed the hold")
            age("claude-s1", by: 0)
        }
        step("one 40 min build (owner tree busy), no touches", ticks: 3, forbid: ["unmute", "pmset sleepnow"]) {
            Sim.set("procs", busy); age("claude-s1", by: 40 * 60)
        }
        check(engine.holds.contains { $0.id == "claude-s1" }, "busy owner keeps an untouched hold")
        step("Esc: no Stop hook, Claude idle at the prompt, 16 min untouched", forbid: ["pmset sleepnow"]) { Sim.set("procs", idle); age("claude-s1", by: 16 * 60) }
        check(!engine.holds.contains { $0.id == "claude-s1" } && engine.graceUntil != nil, "hold dropped after 15 min idle, grace started")
        step("grace runs out", ticks: 61, expect: Self.restoreActions + ["disablesleep 0", "pmset sleepnow"])
        step("PreToolUse with no hold re-creates it", expect: ["log: Claude Code started working"]) { script(Paths.hookScript, ["touch", "claude"], stdin: input) }
        step("Stop (finished confirmed after 10 s)", ticks: 6, expect: ["log: Claude Code finished"]) { script(Paths.hookScript, ["stop", "claude"], stdin: input) }
        check(!fm.fileExists(atPath: holdURL.path), "Stop removes the hold")
        let unparseable = Paths.holds.appendingPathComponent("cli-broken")
        try? "{\"agent\":\"cli\",\"reason\":\"a\tb\n".write(to: unparseable, atomically: true, encoding: .utf8)
        try? fm.setAttributes([.modificationDate: Clock.now().addingTimeInterval(-16 * 60)], ofItemAtPath: unparseable.path)
        step("[10] unparseable hold file 16 min old") {}
        check(!fm.fileExists(atPath: unparseable.path), "unparseable hold is short-lived (not 6 h)")
    }

    /// [2] Only audio is a Discord/Slack call, pauseChatApps on.
    func chatCall() {
        configure(["pauseChatApps": true]); boot()
        step("call audio playing (only trigger)", expect: ["disablesleep 1"]) { Sim.set("audio", "chat") }
        step("close lid: the app in the call is not paused", expect: ["lock screen", "chat apps left running"], forbid: ["SIGSTOP"]) { Sim.set("lid", "closed") }
        step("30 min call under the lid", ticks: 900, forbid: ["pmset sleepnow", "disablesleep 0", "SIGSTOP"])
        check(engine.triggerReason == "music playing", "audio still keeps the Mac awake")
        step("call ends (30 s gap allowance)", ticks: 16, expect: ["disablesleep 0", "pmset sleepnow"]) { Sim.set("audio", "silent") }
        checkRestored()
    }

    /// [3] Flag stuck at Yes with the lid open and the user working.
    func lidStaleActive() {
        Sim.set("lid", "closed"); Sim.set("idle", "1")
        configure(); boot()
        step("Go AFK while typing", ticks: 30, expect: ["disablesleep 1"], forbid: ["lock screen", "mute", "SIGSTOP", "pmset sleepnow"]) { engine.start() }
        step("user reads, display idles to sleep (idle 10 min)", ticks: 30, forbid: ["lock screen", "mute", "SIGSTOP", "pmset sleepnow"]) { Sim.set("idle", "600") }
        check(!engine.lidClosed, "stale Yes is not 'closed' for an active user")
        step("Stop", expect: ["disablesleep 0"], forbid: ["pmset sleepnow"]) { engine.stop() }
        checkRestored()
    }

    /// [3] The panel lighting up under the lid is not an open (no display check).
    /// Input from just before the close (palm on the trackpad) doesn't open it either.
    func lidPanelWake() {
        configure(); boot()
        step("Go AFK", expect: ["disablesleep 1"]) { engine.start() }
        step("close lid, last touch 1 s ago", expect: Self.closeActions) { Sim.set("lid", "closed"); Sim.set("idle", "1") }
        step("login window lights the panel; no input", ticks: 60, expect: ["pmset displaysleepnow"],
             forbid: ["unmute", "Welcome back", "lock screen", "SIGCONT", "pmset sleepnow"]) { Sim.set("idle", "600") }
        check(engine.lidEngaged, "still engaged")
        step("open lid", expect: Self.restoreActions + ["log: Welcome back"], forbid: ["pmset sleepnow"]) { Sim.set("lid", "open") }
        engine.stop()
    }

    /// [3] Launched with a stale Yes and nobody around: counts as closed. Then input
    /// opens it, and it stays open (no ping-pong) until a real clamshell message.
    func lidHidOpen() {
        Sim.set("lid", "closed")
        configure(); boot()
        step("Go AFK, flag Yes, idle 10 min", expect: ["disablesleep 1"] + Self.closeActions) { engine.start() }
        step("keyboard input with the flag still Yes", expect: Self.restoreActions + ["log: Welcome back"], forbid: ["pmset sleepnow"]) { Sim.set("idle", "1") }
        check(!engine.lidClosed && engine.isActive, "open and still awake")
        step("user idles again, flag still Yes", ticks: 60, forbid: ["lock screen", "mute", "pmset sleepnow"]) { Sim.set("idle", "600") }
        step("real close (IOKit message)", expect: Self.closeActions) { Sim.set("lid-event", "closed") }
        step("real open (IOKit message, flag still stale)", expect: Self.restoreActions, forbid: ["pmset sleepnow"]) { Sim.set("lid-event", "open") }
        step("Stop", expect: ["disablesleep 0"], forbid: ["pmset sleepnow"]) { engine.stop() }
        checkRestored()
    }

    /// [3] Docked clamshell: a monitor that drops off briefly (or a CG error)
    /// must not lock / mute / sleep; one that stays gone does.
    func monitorDebounce() {
        Sim.set("lid", "closed"); Sim.set("display", "external"); Sim.set("battery", "100 ac")
        configure(); boot()
        let away = ["log: Lid closed. Still working", "lock screen", "pmset displaysleepnow", "mute"]
        step("Go AFK docked", expect: ["disablesleep 1"], forbid: ["lock screen", "mute", "SIGSTOP"]) { engine.start() }
        step("monitor drops off the bus for 4 s", ticks: 2, forbid: ["lock screen", "mute", "SIGSTOP", "pmset sleepnow"]) { Sim.set("display", "builtin") }
        step("monitor back", ticks: 10, forbid: ["lock screen", "mute", "SIGSTOP", "pmset sleepnow"]) { Sim.set("display", "external") }
        step("CoreGraphics error for 30 s", ticks: 15, forbid: ["lock screen", "mute", "SIGSTOP", "pmset sleepnow"]) { Sim.set("display", "error") }
        step("monitor unplugged for good (20 s)", ticks: 10, expect: away) { Sim.set("display", "builtin") }
        step("Stop", expect: ["SIGCONT chat apps", "unmute", "disablesleep 0", "pmset sleepnow"]) { engine.stop() }
        checkRestored()
    }

    /// [4] disablesleep 0 fails once (sudoers rule gone, transient): retried with backoff.
    func releaseFail() {
        configure(); boot()
        step("Go AFK (lid open)", expect: ["disablesleep 1"]) { engine.start() }
        step("rule removed, then Stop", expect: ["disablesleep 0  (FAILED"]) { Sim.set("setup", "no"); engine.stop() }
        check(engine.lidOverrideOn, "UI keeps showing the override as on while it is")
        step("still failing: one retry per 30 s, not every tick", ticks: 15) {}
        let tries = readLog().filter { $0.contains("disablesleep 0  (FAILED") }.count
        check(tries == 2, "2 failed attempts in ~30 s (got \(tries))")
        step("rule back (e.g. Set up again), 1 min", ticks: 30, expect: ["sudo pmset -a disablesleep 0"]) { Sim.set("setup", "yes") }
        check(Sim.value("pmset-disablesleep") == "0" && !engine.lidOverrideOn, "disablesleep restored (got \(Sim.value("pmset-disablesleep") ?? "nil"), lidOverrideOn=\(engine.lidOverrideOn))")
        check(!FileManager.default.fileExists(atPath: Paths.lidFlag.path), "lid flag removed")
    }

    /// [5] The charger source has its own Low Power setting, which must survive.
    func lowPowerSource() {
        Sim.set("pmset-lowpowermode-c", "1")
        configure(); boot()
        step("Go AFK on battery", expect: ["disablesleep 1"]) { engine.start() }
        step("close lid", expect: ["sudo pmset -b lowpowermode 1"], forbid: ["-a lowpowermode", "-c lowpowermode"]) { Sim.set("lid", "closed") }
        check((try? String(contentsOf: Paths.lowPowerFlag, encoding: .utf8)) == "b", "restore flag names the battery source")
        step("charger plugged in under the lid", ticks: 3, forbid: ["lowpowermode"]) { Sim.set("battery", "81 ac") }
        step("open lid", expect: ["sudo pmset -b lowpowermode 0"], forbid: ["-a lowpowermode", "-c lowpowermode"]) { Sim.set("lid", "open") }
        check(Sim.value("pmset-lowpowermode-b") == "0" && Sim.value("pmset-lowpowermode-c") == "1", "battery restored, charger setting untouched")
        engine.stop()
        let rule = PowerControl.allowedCommands
        check(rule.contains("/usr/bin/pmset -b lowpowermode 1") && rule.contains("/usr/bin/pmset -c lowpowermode 0")
              && !rule.contains { $0.contains("-a lowpowermode") }, "sudoers allow-list is per source")
        check(Scripts.watchdog.contains("pmset -b lowpowermode 0") && !Scripts.watchdog.contains("-a lowpowermode"), "watchdog restores per source")
    }

    /// [6] `out=$(afkpug run -- echo hi)` returns right away. [10] control characters in --reason.
    func cliScript() {
        configure(); boot()
        let run = script(Paths.cliScript, ["run", "--", "echo", "hi"])
        print("  afkpug run -- echo hi: \(String(format: "%.2f", run.seconds)) s, output \(run.output.debugDescription)")
        check(run.seconds < 5 && run.output == "hi\n" && run.status == 0, "stdout closes when the command ends (not 60 s later)")
        let leftovers = ((try? FileManager.default.contentsOfDirectory(atPath: Paths.holds.path)) ?? []).filter { $0.hasPrefix("run-") }
        check(leftovers.isEmpty, "run hold removed on exit")
        let status = script(Paths.cliScript, ["run", "--", "sh", "-c", "exit 3"]).status
        check(status == 3, "exit status passed through (got \(status))")
        script(Paths.cliScript, ["hold", "--for", "2h", "--reason", "deploy\tprod\nnow \"x\" \\"])
        let file = ((try? FileManager.default.contentsOfDirectory(at: Paths.holds, includingPropertiesForKeys: nil)) ?? []).first { $0.lastPathComponent.hasPrefix("cli-") }
        let json = file.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let span = ((json?["expires"] as? Double) ?? 0) - ((json?["started"] as? Double) ?? 0)
        check(json != nil && span == 7200, "hold JSON parses with its 2 h expiry (span \(span))")
        check((json?["reason"] as? String) == "deployprodnow x ", "reason stripped of quotes, backslashes and control chars (got \(String(describing: json?["reason"])))")
        step("app sees the hold", expect: ["log: Hold · deployprodnow x  started working"]) {}
    }

    /// [7] Each connect failure has its own message, cleared by the next attempt.
    func settingsErrors() {
        configure(); boot()
        try? FileManager.default.createDirectory(at: ClaudeHooks.settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? "[1, 2]".write(to: ClaudeHooks.settingsURL, atomically: true, encoding: .utf8)
        engine.connectClaude()
        check(engine.claudeError != nil && engine.setupError == nil && !engine.claudeConnected, "Claude error shown in its own slot (\(engine.claudeError ?? "nil"))")
        try? "{}".write(to: ClaudeHooks.settingsURL, atomically: true, encoding: .utf8)
        engine.connectClaude()
        check(engine.claudeError == nil && engine.claudeConnected, "Claude error cleared on the next attempt")
        Sim.set("claude", "missing")
        engine.connectMCP()
        check(engine.mcpError != nil && engine.setupError == nil && !engine.mcpConnected && !engine.mcpBusy, "MCP error shown in its own slot (\(engine.mcpError ?? "nil"))")
        Sim.set("claude", nil)
        engine.connectMCP()
        check(engine.mcpError == nil && engine.mcpConnected, "MCP error cleared on the next attempt")
    }

    /// [8] Agent mode off: AFK Pug keeps nothing awake for agents, so holds don't count anywhere.
    func agentModeOff() {
        configure(["agentMode": false]); boot()
        step("claude hold, agent mode off", forbid: ["idle assertion ON", "started working"]) { hold("claude-s1") }
        check(!engine.isActive && engine.holds.isEmpty && engine.headline == tr("Napping"), "not active, headline Napping (got \(engine.headline))")
        step("battery 14%", forbid: ["notify: Battery low"]) { Sim.set("battery", "14 battery") }
        check(engine.trip == nil, "no trip when nothing is kept awake (got \(String(describing: engine.trip)))")
        step("hold removed: no grace", forbid: ["idle assertion ON"]) { dropHold("claude-s1", event: nil) }
        check(engine.graceUntil == nil && !engine.graceActive, "no grace countdown")
    }

    /// [9] Hotkey start() can't clear a guard trip.
    func hotkeyTrip() {
        configure(); boot()
        step("battery 14%, Go AFK", expect: ["notify: Battery low"]) { Sim.set("battery", "14 battery"); engine.start() }
        step("hotkey again", forbid: ["notify: Battery low", "Awake for", "idle assertion ON"]) { engine.start() }
        step("hotkey again", forbid: ["notify: Battery low", "Awake for", "idle assertion ON"]) { engine.start() }
        check(engine.trip == .battery(14) && !engine.manualOn, "trip stays, no session")
        step("plugged in for 30 s: trip clears", ticks: 16, forbid: ["notify: Battery low"]) { Sim.set("battery", "14 ac") }
        check(engine.trip == nil, "trip cleared after steady AC")
        step("Go AFK works again", expect: ["log: Awake for 2h"]) { engine.start() }
        engine.stop()
    }

    /// [11] The MCP server clamps any `minutes` value instead of trapping.
    func mcpClamp() {
        configure(); boot()
        var lines: [String] = []
        for (n, minutes) in ["1e300", "-5", "\"nan\"", "90"].enumerated() {
            lines.append(#"{"jsonrpc":"2.0","id":\#(n + 1),"method":"tools/call","params":{"name":"keep_mac_awake","arguments":{"minutes":\#(minutes),"reason":"r\#(n)"}}}"#)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        process.arguments = ["--mcp"]
        process.environment = ProcessInfo.processInfo.environment
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        do { try process.run() } catch { fail("could not launch --mcp"); return }
        input.fileHandleForWriting.write(Data((lines.joined(separator: "\n") + "\n").utf8))
        try? input.fileHandleForWriting.close()
        let reply = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        check(process.terminationStatus == 0 && reply.split(separator: "\n").count == 4, "server answered all 4 calls without trapping (status \(process.terminationStatus))")
        var spans: [String: Double] = [:]
        for url in (try? FileManager.default.contentsOfDirectory(at: Paths.holds, includingPropertiesForKeys: nil)) ?? [] where url.lastPathComponent.hasPrefix("mcp-") {
            if let json = (try? Data(contentsOf: url)).flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }),
               let reason = json["reason"] as? String {
                spans[reason] = ((json["expires"] as? Double) ?? 0) - ((json["started"] as? Double) ?? 0)
            }
        }
        let errors = reply.split(separator: "\n").filter { $0.contains("\"isError\":true") }.count
        check(errors == 3, "1e300, -5 and \"nan\" are tool errors the model can fix (got \(errors))")
        check(spans == ["r3": 90 * 60], "only the valid 90 min call made a hold (got \(spans))")
    }

    /// Events written while the app wasn't running are dropped at launch, fresh ones kept.
    func sleepNowScenario() {
        configure(); boot()
        step("music playing", expect: ["idle assertion ON"]) { Sim.set("audio", "playing") }
        check(engine.canSleepNow && engine.musicApps == ["Music"], "Sleep now offered, Music shown")
        step("Sleep now", expect: ["log: Sleeping now", "idle assertion OFF"]) { engine.sleepNow() }
        step("music keeps playing: stays snoozed", ticks: 30, forbid: ["idle assertion ON"])
        step("music stops for a while", ticks: 20) { Sim.set("audio", "silent") }
        step("music again: awake again", expect: ["idle assertion ON"]) { Sim.set("audio", "playing") }
        step("agent hold ends: grace", ticks: 2) { Sim.set("audio", "silent"); hold("claude-g1") }
        step("hold gone", ticks: 20) { dropHold("claude-g1") }
        check(engine.canSleepNow, "grace can be cut short")
        step("Sleep now during grace", expect: ["idle assertion OFF"]) { engine.sleepNow() }
        check(!engine.isActive, "asleep-able right away")
        step("Go AFK, then Sleep now", expect: ["idle assertion ON", "log: Sleeping now", "idle assertion OFF"]) { engine.start(); engine.tick(); engine.sleepNow() }
        check(!engine.manualOn, "manual session ended")
    }

    func urlScheme() {
        configure(); boot()
        step("afkpug://start?minutes=45", expect: ["log: Awake for 45m"]) { engine.handle(url: URL(string: "afkpug://start?minutes=45")!) }
        check(engine.manualOn && engine.selectedMinutes == 45, "45 min session")
        step("afkpug://stop", expect: ["log: Stopped"]) { engine.handle(url: URL(string: "afkpug://stop")!) }
        step("afkpug://toggle", expect: ["log: Awake for 45m"]) { engine.handle(url: URL(string: "afkpug://toggle")!) }
        step("afkpug://toggle again", expect: ["log: Stopped"]) { engine.handle(url: URL(string: "afkpug://toggle")!) }
        step("garbage is ignored", forbid: ["Awake for", "Stopped"]) {
            engine.handle(url: URL(string: "afkpug://start?minutes=-5")!)
            engine.handle(url: URL(string: "afkpug://start?minutes=abc")!)
            engine.handle(url: URL(string: "afkpug://format-disk")!)
            engine.handle(url: URL(string: "https://evil.example/start")!)
        }
        check(!engine.manualOn, "nothing started by bad URLs")
    }

    func uninstallAll() {
        configure(); boot()
        do { try ClaudeHooks.install() } catch { fail("install hooks: \(error)") }
        for item in [AgentIntegrations.codex, AgentIntegrations.gemini, AgentIntegrations.cursor] {
            do { try item.connect() } catch { fail("connect \(item.name): \(error)") }
        }
        step("Go AFK, close the lid", expect: ["disablesleep 1", "lock screen"]) { engine.start(); Sim.set("lid", "closed") }
        step("uninstall", expect: ["SIGCONT chat apps", "unmute", "disablesleep 0", "uninstall: launchctl bootout", "uninstall finished (0 problem(s))"]) { engine.uninstallEverything() }
        check(!ClaudeHooks.isInstalled(), "Claude Code hooks removed")
        check(!AgentIntegrations.codex.isConnected() && !AgentIntegrations.gemini.isConnected() && !AgentIntegrations.cursor.isConnected(), "Codex, Gemini CLI and Cursor hooks removed")
        check(!FileManager.default.fileExists(atPath: Paths.root.appendingPathComponent("holds").path), "~/.afkpug removed")
        check(!engine.lidOverrideOn && !engine.isActive, "nothing left running")
    }

    func procsMatrix() {
        let cases: [(String, String?)] = [
            ("codex", "Codex"),
            ("/opt/homebrew/bin/codex exec fix the tests", "Codex"),
            ("node /opt/homebrew/lib/node_modules/@openai/codex/bin/codex.js", "Codex"),
            ("node /Users/u/.npm-global/bin/gemini", "Gemini CLI"),
            ("node /opt/homebrew/lib/node_modules/@google/gemini-cli/dist/index.js", "Gemini CLI"),
            ("/Users/u/.local/share/cursor-agent/versions/2025.10/node /Users/u/.local/share/cursor-agent/versions/2025.10/index.js", "Cursor Agent"),
            ("cursor-agent", "Cursor Agent"),
            ("/Users/u/.local/bin/aider --model x", "Aider"),
            ("python3 /Users/u/.local/pipx/venvs/aider-chat/bin/aider", "Aider"),
            ("opencode", "OpenCode"),
            ("amp", "Amp"),
            ("goose session", "Goose"),
            ("qwen", "Qwen Code"),
            ("/Applications/Codex.app/Contents/MacOS/Codex", nil),
            ("/Applications/Goose.app/Contents/MacOS/Goose", nil),
            ("/Applications/Codex.app/Contents/Resources/codex app-server", nil),
            ("grep amp", nil),
            ("vim gemini.md", nil),
            ("less /tmp/codex.log", nil),
            ("node /Users/u/src/amp.js", nil),
            ("python3 scripts/aider.py", nil),
            ("/usr/libexec/ampd", nil),
            ("git -C codex status", nil),
            ("/Users/u/Documents/Code/AFK Pug/dist/AFK Pug.app/Contents/MacOS/AFKPug", nil),
            ("node /Users/u/projects/codex-clone/server.js", nil),
        ]
        for (line, want) in cases {
            let got = ProcessWatcher.match(Substring(line))
            check(got == want, "'\(line)' -> \(want ?? "nil") (got \(got ?? "nil"))")
        }
    }

    func staleEvents() {
        configure()
        Paths.ensure()
        let old = Paths.events.appendingPathComponent("17000000001-claude-done")
        let fresh = Paths.events.appendingPathComponent("17000000002-claude-waiting")
        FileManager.default.createFile(atPath: old.path, contents: Data())
        FileManager.default.createFile(atPath: fresh.path, contents: Data())
        try? FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-600)], ofItemAtPath: old.path)
        logOffset = readLog().count
        step("launch", ticks: 0, expect: ["notify: Claude Code needs you"], forbid: ["finished"]) { Sim.headless = true; engine.boot() }
        check(((try? FileManager.default.contentsOfDirectory(atPath: Paths.events.path)) ?? []).isEmpty, "old event deleted too")
        step("a later event still fires (confirmed after 10 s)", ticks: 6, expect: ["notify: Claude Code finished"]) { dropHold("none") }
    }

    /// [13] Thai popover after 85 min closed. The Claude hold has a busy owner,
    /// so it survives 15 min staleness; durations come from TimelineViews.
    func previewTh() {
        configure(); boot()
        L10n.language = .th
        let me = getpid()
        Sim.set("procs", "  \(me)     1   0.4 claude\n  9001 \(me)  60.0 cargo build\n")
        step("hold + close") { hold("claude-s1", pid: me); hold("cli-x", agent: "cli", expires: 3 * 3600); engine.start(); Sim.set("lid", "closed") }
        step("85 min closed", ticks: 85, every: 60) { Sim.set("battery", "41 battery"); Sim.set("thermal", "serious") }
        step("open") { Sim.set("lid", "open") }
        check(engine.holds.contains { $0.id == "claude-s1" }, "busy Claude hold still listed")
        let out = ProcessInfo.processInfo.environment["AFKPUG_PREVIEW"] ?? Sim.dir.appendingPathComponent("preview-th.png").path
        try? FileManager.default.removeItem(atPath: out)
        Main.renderPreview(to: out, settings: false)
        check(FileManager.default.fileExists(atPath: out), "preview rendered to \(out)")
    }

    /// Renders every main state to $AFKPUG_PREVIEW-<state>.png for design review.
    func previewStates() {
        configure(["graceMinutes": 15, "lidMode": true]); boot()
        L10n.language = ProcessInfo.processInfo.environment["AFKPUG_LANG"] == "en" ? .en : .th
        let base = ProcessInfo.processInfo.environment["AFKPUG_PREVIEW"] ?? Sim.dir.appendingPathComponent("state").path
        func shot(_ name: String) { Main.renderPreview(to: base + "-" + name + ".png", settings: false) }
        Sim.set("setup", "no"); engine.tick()
        step("setup needed") {}; shot("setup")
        Sim.set("setup", "yes")
        step("idle") {}; shot("idle")
        step("manual") { engine.start() }; shot("manual")
        step("stop") { engine.stop() }
        step("music") { Sim.set("audio", "playing") }; shot("music")
        step("music off", ticks: 20) { Sim.set("audio", "silent") }
        step("agents") { hold("claude-s1"); hold("codex-very-long-agent-name-runner", agent: "gemini-cli-experimental-agent-runner"); hold("cli-x", agent: "cli", expires: 3600); hold("x4", agent: "aider") }
        shot("agents")
        step("grace", ticks: 8) { dropHold("claude-s1"); dropHold("codex-very-long-agent-name-runner", event: nil); dropHold("cli-x", event: nil); dropHold("x4", event: nil) }
        shot("grace")
        step("battery trip", ticks: 2) { engine.sleepNow(); Sim.set("battery", "12 battery"); engine.start() }
        shot("battery")
    }

    /// Renders the working and grace states (big text = agent count, then the countdown).
    func previewGrace() {
        configure(["graceMinutes": 15]); boot()
        L10n.language = ProcessInfo.processInfo.environment["AFKPUG_LANG"] == "en" ? .en : .th
        let base = ProcessInfo.processInfo.environment["AFKPUG_PREVIEW"] ?? Sim.dir.appendingPathComponent("preview").path
        step("two agents working") { hold("claude-s1"); hold("codex-1", agent: "codex") }
        Main.renderPreview(to: base + "-working.png", settings: false)
        step("both finish, 22 s into grace", ticks: 11) { dropHold("claude-s1"); dropHold("codex-1", event: nil) }
        check(engine.graceActive, "in grace")
        Main.renderPreview(to: base + "-grace.png", settings: false)
    }
}

// MARK: - Stress scenarios (adversarial)
//
//     AFKPUG_SIM=1 AFKPug --simulate stress          # every stress scenario, one process each
//     AFKPUG_SIM=1 AFKPug --simulate stress-flap     # one of them
//
// Every tick of every stress step is audited against the session invariants:
//   [inv1] when a path ends: disablesleep 0, Low Power / mute exactly as before, no app
//          left SIGSTOPped, no restore flags left
//   [inv2] no sleepnow / lock while the user is active (idle < 60 s) with the lid open
//   [inv3] no mute / lock unless the lid is really closed with no monitor (away)
//   [inv4] no identical side effect on 3 ticks in a row (spam)
//   [inv5] no identical notification twice within 60 s

extension Simulation {
    static let stressScenarios: [(name: String, about: String)] = [
        ("stress-flap", "lid close/open flapping every tick, then every ~30 s"),
        ("stress-battery-drain", "hours under the lid, battery drains past the floor, on and off AC"),
        ("stress-battery-noise", "battery reading jitters around the floor on battery"),
        ("stress-charger-flaky", "loose charger at the floor with the lid open: plug/unplug every 4 s"),
        ("stress-thermal-osc", "thermal serious<->fair, then serious<->critical, under the lid"),
        ("stress-thermal-flap-open", "thermal critical<->fair with an agent working, lid open"),
        ("stress-music-gap", "music is the only reason: a 2 s gap between tracks under the lid"),
        ("stress-music-flap", "music starts/stops every tick under the lid during a manual session"),
        ("stress-agent-grace-flap", "agent holds appear/disappear during grace under the lid"),
        ("stress-grace-change", "graceMinutes changed during grace"),
        ("stress-manual-expire", "manual 30 min timer expires with the lid closed"),
        ("stress-hotkey", "hotkey in every state"),
        ("stress-lidmode-off", "lidMode off (and back on) while closed"),
        ("stress-keepmusic-off", "keepMusic off while music is the only reason"),
        ("stress-agentmode-off", "agentMode off with holds while closed, and back on"),
        ("stress-pausechat-toggle", "pauseChatApps toggled while apps are paused"),
        ("stress-settings-misc", "mute/lowpower/display/lock settings toggled mid-session"),
        ("stress-display-dock", "external display attach/detach while closed"),
        ("stress-display-error", "CoreGraphics display error while closed with no monitor"),
        ("stress-setup-removed", "setup removed mid-session (lid open), then close"),
        ("stress-rule-vanishes", "sudoers rule vanishes while engaged, SleepDisabled stays 1"),
        ("stress-release-fail-unplug", "release fails while the charger is unplugged (lid only on power)"),
        ("stress-shutdown-engaged", "quit while engaged on battery"),
        ("stress-shutdown-grace", "quit during grace under the lid"),
        ("stress-shutdown-tripped", "quit after a battery trip"),
        ("stress-shutdown-music", "quit after music unmuted under the lid"),
        ("stress-shutdown-thermal", "quit after thermal LPM on AC, then unplugged"),
        ("stress-shutdown-docked", "quit while docked in clamshell"),
        ("stress-crash-engaged", "crash while engaged on battery, relaunch lid open"),
        ("stress-crash-music", "crash after music unmuted under the lid, relaunch"),
        ("stress-crash-thermal", "crash after thermal LPM on AC then unplugged, relaunch"),
        ("stress-crash-grace", "crash during grace, relaunch"),
        ("stress-crash-tripped", "crash after a battery trip, relaunch"),
        ("stress-crash-lpm-preset", "crash with the user's own charger LPM on, relaunch on AC"),
        ("stress-crash-closed", "crash while engaged, relaunch with the lid still closed and work pending"),
        ("stress-crash-releasefail", "crash while disablesleep 0 is failing, relaunch with the rule still gone"),
        ("stress-clock-forward", "sleep/wake gaps of hours (clock jumps forward)"),
        ("stress-clock-back", "wall clock set back an hour during grace and while engaged"),
        ("stress-stale-rearm", "stale clamshell Yes, lid open: a new session re-arms the 60 s rule"),
        ("stress-hid-under-lid", "HID input under a real close, then idle again"),
        ("stress-unplug-lpm", "closed on AC, then unplugged: Low Power Mode on battery?"),
        ("stress-lpm-exact", "user's own Low Power settings on both sources survive"),
        ("stress-autopower", "charger trigger: close on AC, unplug, replug"),
        ("stress-events-closed", "agent turns finishing under the lid"),
        ("stress-watchdog", "watchdog script logic with every command replaced by a logger"),
        ("stress-hid-battery", "HID input under a real close, then the battery floor trips"),
        ("stress-procs-linger", "process-detected agent busy/idle under the lid, then grace"),
        ("stress-remove-setup-closed", "permission removed / set up again while closed (Screen Sharing)"),
        ("stress-soak-8h", "8 h under the lid with an agent hold: only the display push repeats"),
    ]
}

extension Runner {
    // MARK: Harness

    func effectText(_ line: String) -> String {
        guard let r = line.range(of: "] ") else { return line }
        return String(line[r.upperBound...])
    }

    func isEffect(_ e: String) -> Bool { !(e.hasPrefix("log:") || e.hasPrefix("---") || e.hasPrefix("===")) }

    func vfail(_ message: String) {
        guard reported.insert(message).inserted else { return }
        fail(message)
    }

    func audit(_ lines: [String], _ label: String) {
        let effects = lines.map(effectText).filter(isEffect)
        let idle = TimeInterval(Sim.value("idle") ?? "") ?? 600
        let away = !truthOpen && !truthDocked
        let engagedNow = lines.contains { $0.contains("log: Lid closed. Still working") }
        let world = "lid \(truthOpen ? "open" : "closed"), \(truthDocked ? "monitor attached" : "no monitor"), idle \(Int(idle)) s"
        for e in effects {
            if e.hasPrefix("BLOCKED") { vfail("[safety] \(e)") }
            if e.hasPrefix("lock screen") || e == "mute" {
                if truthOpen && idle < 60 { vfail("[inv2] '\(e)' while the user is active with the lid open (\(world)) in '\(label)'") }
                else if !away { vfail("[inv3] '\(e)' while not lid-closed-away (\(world)) in '\(label)'") }
            }
            if e == "pmset sleepnow" {
                if truthOpen && idle < 60 { vfail("[inv2] sleepnow while the user is active with the lid open (\(world)) in '\(label)'") }
                else if truthOpen { vfail("[inv2-soft] sleepnow with the lid open (\(world)) in '\(label)'") }
                if truthDocked { vfail("[inv3] sleepnow while docked (\(world)) in '\(label)'") }
            }
            if e.hasPrefix("notify:") {
                let title = String(e.dropFirst(8)).components(separatedBy: " | ").first ?? ""
                let t = Sim.clockOffset
                if !allowRepeat, notifies.contains(where: { $0.title == title && abs(t - $0.t) < 60 }) {
                    vfail("[inv5] notification '\(title)' repeated within 60 s in '\(label)'")
                }
                notifies.append((t, title))
            }
            if e == "pmset displaysleepnow" {
                let gap = Sim.clockOffset - lastDisplayOffAt
                if !engagedNow, !allowRepeat, gap >= 0, gap < 25 { vfail("[inv4] displaysleepnow again after \(Int(gap)) s in '\(label)'") }
                lastDisplayOffAt = Sim.clockOffset
            }
        }
        let set = Set(effects.filter { $0 != "pmset displaysleepnow" && !$0.hasPrefix("notify:") && !$0.hasPrefix("ntfy") })
        recentTicks.append(set)
        if recentTicks.count > 3 { recentTicks.removeFirst() }
        if !allowRepeat, recentTicks.count == 3 {
            for e in recentTicks[0] where recentTicks[1].contains(e) && recentTicks[2].contains(e) {
                vfail("[inv4] '\(e)' on 3 ticks in a row in '\(label)'")
            }
        }
    }

    /// Like `step`, but every tick is audited against the invariants.
    func st(_ label: String, ticks: Int = 1, every: TimeInterval = 2, expect: [String] = [], forbid: [String] = [],
            _ change: () -> Void = {}) {
        Sim.record("--- \(label)")
        change()
        var collected: [String] = []
        let pre = Array(readLog().dropFirst(logOffset))
        logOffset += pre.count
        if pre.contains(where: { isEffect(effectText($0)) }) { audit(pre, label) }
        collected += pre
        for _ in 0..<ticks {
            Sim.clockOffset += every
            engine.tick()
            let lines = Array(readLog().dropFirst(logOffset))
            logOffset += lines.count
            audit(lines, label)
            collected += lines
        }
        if printLines { for line in collected { print("  " + line) } }
        var index = 0
        var missing: [String] = []
        for want in expect {
            if let hit = collected[index...].firstIndex(where: { $0.contains(want) }) { index = hit + 1 } else { missing.append(want) }
        }
        let bad = forbid.filter { f in collected.contains { $0.contains(f) } }
        if !missing.isEmpty { fail("missing in '\(label)' (in order): \(missing)") }
        if !bad.isEmpty { fail("unexpected in '\(label)': \(bad)") }
    }

    func closeLid(idle: String = "600") { Sim.set("lid", "closed"); Sim.set("idle", idle); truthOpen = false }
    func openLid(idle: String = "1") { Sim.set("lid", "open"); Sim.set("idle", idle); truthOpen = true }
    func dock(_ on: Bool) { Sim.set("display", on ? "external" : "builtin"); truthDocked = on }

    func snapshot() -> [String: String] {
        ["muted": Sim.value("muted") ?? "0", "b": Sim.value("pmset-lowpowermode-b") ?? "0", "c": Sim.value("pmset-lowpowermode-c") ?? "0"]
    }

    func bootS(_ values: [String: Any] = [:]) {
        configure(values)
        baseline = snapshot()
        boot()
    }

    func count(_ needle: String) -> Int { readLog().filter { $0.contains(needle) }.count }

    func verifyRestored(_ when: String, allowActive: Bool = false) {
        let fm = FileManager.default
        func c(_ ok: Bool, _ what: String) { check(ok, "[inv1 \(when)] \(what)") }
        c(Sim.value("pmset-disablesleep") == "0", "disablesleep 0 (got \(Sim.value("pmset-disablesleep") ?? "nil"))")
        c(Sim.value("muted") == baseline["muted"], "mute exactly as before (got \(Sim.value("muted") ?? "nil"), was \(baseline["muted"] ?? "?"))")
        let now = snapshot()
        c(now["b"] == baseline["b"] && now["c"] == baseline["c"],
          "Low Power exactly as before (b \(baseline["b"]!)->\(now["b"]!), c \(baseline["c"]!)->\(now["c"]!))")
        c(!fm.fileExists(atPath: ChatPauser.file.path), "no app left SIGSTOPped")
        c(!fm.fileExists(atPath: Paths.lidFlag.path) && !fm.fileExists(atPath: Paths.muteFlag.path)
          && !fm.fileExists(atPath: Paths.lowPowerFlag.path), "no flag files left")
        c(!engine.lidEngaged && !engine.lidOverrideOn, "lid actions and override off")
        if !allowActive { c(!engine.isActive, "not active") }
    }

    func removeAllHolds() {
        let fm = FileManager.default
        for f in (try? fm.contentsOfDirectory(atPath: Paths.holds.path)) ?? [] {
            try? fm.removeItem(at: Paths.holds.appendingPathComponent(f))
        }
    }

    /// Ends every reason to stay awake, opens the lid and waits out any grace.
    func endAll() {
        st("end every reason, open the lid, wait out grace", ticks: 40, every: 30) {
            // Open first: stop() ticks synchronously.
            if !truthOpen { openLid(idle: "600") }
            removeAllHolds()
            Sim.set("audio", "silent"); Sim.set("apps", nil); Sim.set("procs", nil)
            engine.stop()
        }
        verifyRestored("after the path ended")
    }

    func spawnSelf(_ scenario: String) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        process.arguments = ["--simulate", scenario]
        var env = ProcessInfo.processInfo.environment
        env["AFKPUG_SIM"] = "1"
        env["AFKPUG_SIM_DIR"] = Sim.dir.path
        process.environment = env
        do { try process.run() } catch { fail("could not launch \(scenario)"); return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }

    static let away = ["log: Lid closed. Still working", "lock screen", "pmset displaysleepnow"]

    // MARK: Dispatch

    func runStress() {
        if name.hasPrefix("stress-crashchild-") { crashChild(String(name.dropFirst("stress-crashchild-".count))); return }
        if name.hasPrefix("stress-crash-") { crashParent(String(name.dropFirst("stress-crash-".count))); return }
        if name.hasPrefix("stress-shutdown-") { shutdownPhase(String(name.dropFirst("stress-shutdown-".count))); return }
        switch name {
        case "stress-flap": sFlap()
        case "stress-battery-drain": sBatteryDrain()
        case "stress-battery-noise": sBatteryNoise()
        case "stress-charger-flaky": sChargerFlaky()
        case "stress-thermal-osc": sThermalOsc()
        case "stress-thermal-flap-open": sThermalFlapOpen()
        case "stress-music-gap": sMusicGap()
        case "stress-music-flap": sMusicFlap()
        case "stress-agent-grace-flap": sAgentGraceFlap()
        case "stress-grace-change": sGraceChange()
        case "stress-manual-expire": sManualExpire()
        case "stress-hotkey": sHotkey()
        case "stress-lidmode-off": sLidModeOff()
        case "stress-keepmusic-off": sKeepMusicOff()
        case "stress-agentmode-off": sAgentModeOff()
        case "stress-pausechat-toggle": sPauseChatToggle()
        case "stress-settings-misc": sSettingsMisc()
        case "stress-display-dock": sDisplayDock()
        case "stress-display-error": sDisplayError()
        case "stress-setup-removed": sSetupRemoved()
        case "stress-rule-vanishes": sRuleVanishes()
        case "stress-release-fail-unplug": sReleaseFailUnplug()
        case "stress-clock-forward": sClockForward()
        case "stress-clock-back": sClockBack()
        case "stress-stale-rearm": sStaleRearm()
        case "stress-hid-under-lid": sHidUnderLid()
        case "stress-unplug-lpm": sUnplugLpm()
        case "stress-lpm-exact": sLpmExact()
        case "stress-autopower": sAutoPower()
        case "stress-events-closed": sEventsClosed()
        case "stress-watchdog": sWatchdog()
        case "stress-hid-battery": sHidBattery()
        case "stress-procs-linger": sProcsLinger()
        case "stress-remove-setup-closed": sRemoveSetupClosed()
        case "stress-soak-8h": sSoak()
        default: fail("no stress scenario \(name)")
        }
    }

    // MARK: Scenarios

    func sFlap() {
        bootS()
        st("Go AFK", expect: ["disablesleep 1"]) { engine.start() }
        allowRepeat = true
        for i in 1...20 {
            st("flap: close #\(i)", expect: ["log: Lid closed. Still working", "lock screen", "mute"], forbid: ["pmset sleepnow"]) { closeLid() }
            st("flap: open #\(i)", expect: ["SIGCONT chat apps", "unmute"], forbid: ["pmset sleepnow", "lock screen", "While you were away", "disablesleep 0"]) { openLid() }
            if engine.lidEngaged { vfail("still engaged after open #\(i)") }
        }
        for i in 1...4 {
            st("closed 30 s #\(i)", ticks: 15, expect: ["lock screen"], forbid: ["pmset sleepnow"]) { closeLid() }
            st("open #\(i)", expect: ["unmute", "notify: While you were away"], forbid: ["pmset sleepnow"]) { openLid() }
        }
        allowRepeat = false
        st("steady open 1 min", ticks: 30, forbid: ["lock screen", "mute", "pmset"])
        check(count("lock screen") == 24 && count("] unmute") == 24, "one lock and one unmute per close (locks \(count("lock screen")), unmutes \(count("] unmute")))")
        endAll()
    }

    func sBatteryDrain() {
        Sim.set("battery", "60 battery")
        bootS()
        st("12 h CLI hold") { hold("cli-long", agent: "cli", expires: 12 * 3600) }
        st("close lid", expect: Self.closeActions) { closeLid() }
        var p = 60
        while p > 30 {
            p -= 1
            let pct = p
            st("drain to \(pct)% on battery", ticks: 5, every: 60, forbid: ["pmset sleepnow", "Battery low", "lock screen"]) { Sim.set("battery", "\(pct) battery") }
        }
        st("charger in at 30% under the lid", ticks: 20, every: 60, forbid: ["pmset sleepnow", "lowpowermode", "lock screen", "mute"]) { Sim.set("battery", "30 ac") }
        st("charged to 40%, unplugged", ticks: 5, every: 60, forbid: ["pmset sleepnow", "lock screen"]) { Sim.set("battery", "40 battery") }
        while p > 16 {
            p -= 1
            let pct = p
            st("drain to \(pct)%", ticks: 5, every: 60, forbid: ["pmset sleepnow", "Battery low"]) { Sim.set("battery", "\(pct) battery") }
        }
        st("drain to 15%: floor", expect: ["log: Battery at 15%", "notify: Battery low", "unmute", "lowpowermode 0", "disablesleep 0", "pmset sleepnow"]) { Sim.set("battery", "15 battery") }
        st("keeps draining under the lid", ticks: 30, every: 60, forbid: ["disablesleep 1", "lock screen", "Battery low"]) { Sim.set("battery", "12 battery") }
        st("charger in at 12% (still closed): steady 30 s, trip clears, hold resumes", ticks: 18, expect: ["disablesleep 1", "lock screen"]) { Sim.set("battery", "12 ac") }
        check(engine.trip == nil && engine.lidEngaged, "re-engaged on AC")
        st("unplugged at 12%", expect: ["notify: Battery low", "disablesleep 0", "pmset sleepnow"]) { Sim.set("battery", "12 battery") }
        check(count("notify: Battery low") == 2, "two battery notifications, one per unplug (got \(count("notify: Battery low")))")
        verifyRestored("after the battery trip", allowActive: false)
        st("charger in again for the end", ticks: 2) { Sim.set("battery", "13 ac") }
        endAll()
    }

    func sBatteryNoise() {
        Sim.set("battery", "17 battery")
        bootS()
        st("Go AFK at 17%") { engine.start() }
        st("close", expect: Self.closeActions) { closeLid() }
        for i in 0..<60 {
            let pct = [16, 15, 16, 15, 14, 16][i % 6]
            st("jitter \(pct)%", forbid: i == 0 ? [] : ["disablesleep 1"]) { Sim.set("battery", "\(pct) battery") }
        }
        check(count("notify: Battery low") == 1, "one battery notification despite jitter (got \(count("notify: Battery low")))")
        st("plug in", ticks: 2) { Sim.set("battery", "16 ac") }
        endAll()
    }

    func sChargerFlaky() {
        Sim.set("battery", "15 ac")
        bootS()
        st("12 h CLI hold, lid open, user reading", ticks: 2, expect: ["disablesleep 1"]) { hold("cli-long", agent: "cli", expires: 12 * 3600); openLid(idle: "30") }
        for i in 0..<15 {
            st("loose cable: unplugged #\(i)") { Sim.set("battery", "15 battery") }
            st("loose cable: plugged #\(i)") { Sim.set("battery", "15 ac") }
        }
        let n = count("notify: Battery low")
        check(n <= 2, "battery notification not repeated for every cable wiggle (got \(n) in 60 s)")
        endAll()
    }

    func sThermalOsc() {
        Sim.set("battery", "90 ac")
        bootS()
        st("Go AFK on AC") { engine.start() }
        st("close", expect: ["lock screen", "mute"], forbid: ["lowpowermode"]) { closeLid() }
        for i in 0..<60 {
            st("serious/fair #\(i)", forbid: i == 0 ? ["pmset sleepnow"] : ["pmset sleepnow", "lowpowermode"]) { Sim.set("thermal", i % 2 == 0 ? "serious" : "fair") }
        }
        check(count("sudo pmset -c lowpowermode 1") == 1, "charger LPM turned on once (got \(count("sudo pmset -c lowpowermode 1")))")
        for i in 0..<30 {
            st("serious/critical #\(i)") { Sim.set("thermal", i % 2 == 0 ? "critical" : "serious") }
        }
        check(count("notify: Too hot") == 1 && engine.trip == .thermal, "one heat trip while it never cools to fair (got \(count("notify: Too hot")))")
        st("cools to fair", ticks: 3, forbid: ["disablesleep 1"]) { Sim.set("thermal", "fair") }
        endAll()
    }

    func sThermalFlapOpen() {
        Sim.set("battery", "90 ac")
        bootS()
        st("12 h CLI hold, lid open, user working", expect: ["disablesleep 1"]) { hold("cli-long", agent: "cli", expires: 12 * 3600); openLid(idle: "5") }
        for i in 0..<20 {
            st("critical #\(i)") { Sim.set("thermal", "critical") }
            st("fair #\(i)") { Sim.set("thermal", "fair") }
        }
        let n = count("notify: Too hot")
        check(n <= 2, "heat notification not repeated every oscillation (got \(n) in 80 s)")
        st("slower: critical 30 s / fair 30 s for 10 min", ticks: 0) {}
        let before = count("notify: Too hot")
        for i in 0..<10 {
            st("critical 30 s #\(i)", ticks: 15) { Sim.set("thermal", "critical") }
            st("fair 30 s #\(i)", ticks: 15) { Sim.set("thermal", "fair") }
        }
        check(count("notify: Too hot") - before <= 2, "heat notification at most twice in 10 min of 1-min oscillation (got \(count("notify: Too hot") - before))")
        endAll()
    }

    func sMusicGap() {
        bootS()
        st("music playing (only reason)", expect: ["disablesleep 1"]) { Sim.set("audio", "playing") }
        st("close lid", expect: ["lock screen"], forbid: ["mute"]) { closeLid() }
        st("5 min of music", ticks: 150, forbid: ["pmset sleepnow"])
        st("2 s of silence between tracks", forbid: ["pmset sleepnow", "disablesleep 0"]) { Sim.set("audio", "silent") }
        st("next track", ticks: 10) { Sim.set("audio", "playing") }
        endAll()
    }

    func sMusicFlap() {
        bootS()
        st("Go AFK") { engine.start() }
        st("close (silent: muted)", expect: ["mute"]) { closeLid() }
        for i in 0..<30 {
            st("music \(i % 2 == 0 ? "on" : "off") #\(i)", forbid: ["pmset sleepnow", "disablesleep 0"]) { Sim.set("audio", i % 2 == 0 ? "playing" : "silent") }
        }
        check(count("] unmute") == 1 && count("] mute") == 1, "one mute, one unmute (mute \(count("] mute")), unmute \(count("] unmute")))")
        endAll()
    }

    func sAgentGraceFlap() {
        bootS()
        st("hold", expect: ["disablesleep 1"]) { hold("claude-s1") }
        st("close", expect: Self.closeActions) { closeLid() }
        for i in 0..<20 {
            st("hold gone #\(i)", ticks: 15, forbid: ["pmset sleepnow", "unmute", "disablesleep 0"]) { dropHold("claude-s1", event: nil) }
            check(engine.graceUntil != nil, "grace running")
            st("hold back #\(i)", forbid: ["pmset sleepnow", "unmute"]) { hold("claude-s1") }
            check(engine.graceUntil == nil, "grace cancelled")
        }
        st("hold gone for good", ticks: 59, forbid: ["pmset sleepnow"]) { dropHold("claude-s1") }
        st("grace ends", ticks: 2, expect: ["unmute", "disablesleep 0", "pmset sleepnow"])
        endAll()
    }

    func sGraceChange() {
        bootS(["graceMinutes": 15])
        st("hold", expect: ["disablesleep 1"]) { hold("claude-s1") }
        st("close", expect: Self.closeActions) { closeLid() }
        st("hold gone: 15 min grace", ticks: 30) { dropHold("claude-s1") }
        st("user picks 2 min (1 min into grace)", ticks: 45) { engine.graceMinutes = 2 }
        check(!engine.isActive, "grace honours the new 2 min setting (still active 2.5 min after the drop: \(engine.isActive), graceUntil in \(Int(engine.graceUntil?.timeIntervalSince(Clock.now()) ?? -1)) s)")
        endAll()
    }

    func sManualExpire() {
        bootS(["selectedMinutes": 30])
        st("Go AFK 30m", expect: ["log: Awake for 30m"]) { engine.start() }
        st("close", expect: Self.closeActions) { closeLid() }
        st("29 min closed", ticks: 29, every: 60, forbid: ["pmset sleepnow", "Timer finished"])
        st("timer expires", ticks: 2, every: 60, expect: ["log: Timer finished", "notify: Time's up", "unmute", "disablesleep 0", "pmset sleepnow"])
        st("lid stays closed 10 min", ticks: 20, every: 30, forbid: ["disablesleep 1", "lock screen", "Time's up", "pmset sleepnow"])
        check(count("notify: Time's up") == 1, "one Time's up")
        endAll()
    }

    func sHotkey() {
        bootS()
        let key = { HotKey.action?() }
        st("hotkey idle: start", expect: ["log: Awake for 2h", "disablesleep 1"]) { key() }
        st("hotkey: stop (lid open)", expect: ["disablesleep 0"], forbid: ["pmset sleepnow"]) { key() }
        st("agent works, lid closed", expect: Self.closeActions) { hold("claude-s1"); closeLid() }
        st("hotkey under the lid: manual start", forbid: ["lock screen", "unmute", "pmset sleepnow"]) { key() }
        check(engine.manualOn, "manual on")
        st("hotkey under the lid: stop, agent still works", forbid: ["unmute", "pmset sleepnow", "disablesleep 0"]) { key() }
        st("agent done: grace", ticks: 10, forbid: ["pmset sleepnow"]) { dropHold("claude-s1") }
        st("hotkey in grace: start", forbid: ["pmset sleepnow", "lock screen"]) { key() }
        st("hotkey in grace: stop", forbid: ["pmset sleepnow"]) { key() }
        st("grace runs out", ticks: 60, expect: ["unmute", "disablesleep 0", "pmset sleepnow"])
        st("battery 14% on battery, lid open: start trips", expect: ["notify: Battery low"]) { openLid(); Sim.set("battery", "14 battery"); key() }
        st("hotkey in trip: nothing", ticks: 3, forbid: ["Awake", "disablesleep 1", "Battery low"]) { key() }
        st("hotkey in trip again", forbid: ["Awake", "disablesleep 1"]) { key() }
        st("plug in", ticks: 2) { Sim.set("battery", "14 ac") }
        st("docked clamshell, user typing", ticks: 3) { closeLid(idle: "1"); dock(true) }
        st("hotkey docked: start", ticks: 5, forbid: ["lock screen", "mute", "SIGSTOP"]) { key() }
        st("hotkey docked: stop", forbid: ["pmset sleepnow"]) { key() }
        st("undock and open", ticks: 2) { dock(false); openLid() }
        endAll()
    }

    func sLidModeOff() {
        bootS()
        st("Go AFK + close", expect: Self.closeActions) { engine.start(); closeLid() }
        st("lidMode off under the lid", expect: ["unmute", "lowpowermode 0", "disablesleep 0", "pmset sleepnow"]) { engine.lidMode = false }
        st("still closed 30 s", ticks: 15, forbid: ["disablesleep 1", "lock screen", "pmset sleepnow"])
        st("lidMode on again under the lid", ticks: 3, expect: ["disablesleep 1", "lock screen"]) { engine.lidMode = true }
        for i in 0..<10 { st("lidMode toggle #\(i)") { engine.lidMode.toggle() } }
        endAll()
    }

    func sKeepMusicOff() {
        bootS()
        st("music only, close", expect: ["lock screen"], forbid: ["] mute"]) { Sim.set("audio", "playing"); closeLid() }
        st("keepMusic off", expect: ["disablesleep 0", "pmset sleepnow"], forbid: ["] mute"]) { engine.keepMusic = false }
        st("30 s", ticks: 15, forbid: ["disablesleep 1", "lock screen", "pmset sleepnow"])
        st("keepMusic on", ticks: 2, expect: ["disablesleep 1", "lock screen"]) { engine.keepMusic = true }
        st("manual + music, keepMusic off: stays awake", ticks: 3, forbid: ["pmset sleepnow", "disablesleep 0"]) { engine.start(); engine.keepMusic = false }
        endAll()
    }

    func sAgentModeOff() {
        bootS()
        st("2 holds, close", expect: Self.closeActions) { hold("claude-s1"); hold("cli-x", agent: "cli", expires: 3600); closeLid() }
        st("agentMode off", expect: ["unmute", "disablesleep 0", "pmset sleepnow"]) { engine.agentMode = false }
        check(engine.graceUntil == nil && engine.holds.isEmpty, "no grace, no holds")
        st("30 s", ticks: 15, forbid: ["disablesleep 1", "lock screen", "pmset sleepnow", "started working"])
        st("agentMode on", ticks: 2, expect: ["started working", "disablesleep 1", "lock screen"]) { engine.agentMode = true }
        st("agentMode off during grace", ticks: 2, expect: ["pmset sleepnow"]) { removeAllHolds(); engine.tick(); engine.agentMode = false }
        check(engine.graceUntil == nil, "grace dropped")
        st("agentMode on again: no grace resurrected", ticks: 5, forbid: ["disablesleep 1", "lock screen"]) { engine.agentMode = true }
        endAll()
    }

    func sPauseChatToggle() {
        bootS(["pauseChatApps": true])
        st("Go AFK + close", expect: ["SIGSTOP chat apps"]) { engine.start(); closeLid() }
        st("pauseChatApps off while paused", ticks: 3) { engine.pauseChatApps = false }
        st("open: resumed anyway", expect: ["SIGCONT chat apps"]) { openLid() }
        st("close again: not paused", forbid: ["SIGSTOP"]) { closeLid() }
        st("pauseChatApps on while closed", ticks: 3, forbid: ["SIGSTOP"]) { engine.pauseChatApps = true }
        st("open", forbid: ["SIGCONT"]) { openLid() }
        st("close: paused", expect: ["SIGSTOP chat apps"]) { closeLid() }
        endAll()
    }

    func sSettingsMisc() {
        bootS()
        st("Go AFK + close", expect: Self.closeActions) { engine.start(); closeLid() }
        st("muteOnClose off while muted", ticks: 3) { engine.muteOnClose = false }
        st("lowPowerOnClose off while LPM on", ticks: 3) { engine.lowPowerOnClose = false }
        st("displayOffOnClose off", ticks: 20, forbid: ["displaysleepnow"]) { engine.displayOffOnClose = false }
        st("lockOnClose off", ticks: 3) { engine.lockOnClose = false }
        st("batteryFloor raised to 85% above 80%", expect: ["notify: Battery low", "unmute", "lowpowermode 0", "disablesleep 0", "pmset sleepnow"]) { engine.batteryFloor = 85 }
        st("floor back", ticks: 2) { engine.batteryFloor = 15 }
        endAll()
    }

    func sDisplayDock() {
        bootS()
        st("Go AFK + close", expect: Self.closeActions) { engine.start(); closeLid() }
        st("monitor attached under the lid", ticks: 3, expect: ["unmute"], forbid: ["pmset sleepnow"]) { dock(true); Sim.set("idle", "1") }
        st("user works docked 1 min", ticks: 30, forbid: ["lock screen", "mute", "pmset sleepnow"])
        allowRepeat = true
        for i in 0..<4 {
            st("monitor off 10 s #\(i)", ticks: 5, forbid: ["lock screen", "] mute"]) { dock(false); Sim.set("idle", "20") }
            st("monitor back #\(i)", ticks: 5, forbid: ["lock screen", "pmset sleepnow"]) { dock(true) }
        }
        allowRepeat = false
        st("monitor unplugged for good, user gone", ticks: 10, expect: Self.away) { dock(false); Sim.set("idle", "600") }
        st("monitor attached again", ticks: 2, expect: ["unmute"], forbid: ["pmset sleepnow"]) { dock(true) }
        st("undock, open", ticks: 2, forbid: ["pmset sleepnow"]) { dock(false); openLid() }
        endAll()
    }

    func sDisplayError() {
        bootS()
        st("Go AFK + close", expect: Self.closeActions) { engine.start(); closeLid() }
        st("1 min closed", ticks: 30)
        st("CoreGraphics error for 4 s (no monitor)", ticks: 2, forbid: ["unmute", "SIGCONT", "Welcome back", "While you were away"]) { Sim.set("display", "error") }
        st("CG back", ticks: 10, forbid: ["lock screen", "] mute"]) { Sim.set("display", "builtin") }
        endAll()
    }

    func sSetupRemoved() {
        bootS()
        st("Go AFK (lid open)", expect: ["disablesleep 1"]) { engine.start() }
        st("Remove lid-closed permission", expect: ["disablesleep 0", "remove sudoers"]) { engine.removeSetup() }
        check(!engine.lidOverrideOn && !engine.setupDone, "override off, setup needed")
        st("close lid", ticks: 10, forbid: ["lock screen", "] mute", "disablesleep 1", "pmset sleepnow"]) { closeLid() }
        st("open, set up again", expect: ["install sudoers", "disablesleep 1"]) { openLid(); engine.runSetup() }
        st("close", expect: Self.closeActions) { closeLid() }
        endAll()
    }

    func sRuleVanishes() {
        bootS()
        st("Go AFK + close", expect: Self.closeActions) { engine.start(); closeLid() }
        st("sudoers rule removed by something else; SleepDisabled stays 1", ticks: 30) { Sim.set("setup", "no") }
        st("Stop under the lid", ticks: 30, expect: ["unmute", "disablesleep 0  (FAILED", "pmset sleepnow"]) { engine.stop() }
        let tries = count("disablesleep 0  (FAILED")
        check(tries <= 3, "release retried with backoff (got \(tries) in 60 s)")
        st("rule back", ticks: 20) { Sim.set("setup", "yes") }
        endAll()
    }

    func sReleaseFailUnplug() {
        Sim.set("battery", "90 ac")
        bootS(["lidOnlyOnPower": true])
        st("Go AFK on AC + close", expect: ["disablesleep 1", "lock screen", "mute"]) { engine.start(); closeLid() }
        st("sudoers rule gone (SleepDisabled stays 1)", ticks: 3) { Sim.set("setup", "no") }
        st("charger unplugged", ticks: 10, expect: ["disablesleep 0  (FAILED", "pmset sleepnow"]) { Sim.set("battery", "89 battery") }
        let locks = count("lock screen")
        check(locks == 1, "locked once, not on every tick (got \(locks) locks, \(count("pmset sleepnow")) sleepnow, \(count("play sound Tink")) chimes in 20 s)")
        st("rule back", ticks: 20) { Sim.set("setup", "yes") }
        endAll()
    }

    // MARK: Shutdown at every phase

    func shutdownPhase(_ phase: String) {
        switch phase {
        case "engaged":
            bootS()
            st("Go AFK + hold + close", expect: Self.closeActions) { engine.start(); hold("claude-s1"); closeLid() }
        case "grace":
            bootS()
            st("hold + close", expect: Self.closeActions) { hold("claude-s1"); closeLid() }
            st("hold gone: grace", ticks: 10) { dropHold("claude-s1") }
        case "tripped":
            bootS()
            st("Go AFK + close", expect: Self.closeActions) { engine.start(); closeLid() }
            st("battery 14%", expect: ["pmset sleepnow"]) { Sim.set("battery", "14 battery") }
        case "music":
            bootS()
            st("Go AFK + close", expect: ["mute"]) { engine.start(); closeLid() }
            st("music under the lid", expect: ["unmute"]) { Sim.set("audio", "playing") }
        case "thermal":
            Sim.set("battery", "90 ac")
            bootS()
            st("Go AFK + close on AC", expect: ["lock screen"]) { engine.start(); closeLid() }
            st("serious", expect: ["-c lowpowermode 1"]) { Sim.set("thermal", "serious") }
            st("unplugged", ticks: 3) { Sim.set("battery", "85 battery") }
        case "docked":
            Sim.set("battery", "100 ac")
            bootS()
            st("docked, Go AFK", ticks: 3, expect: ["disablesleep 1"]) { closeLid(idle: "1"); dock(true); engine.start() }
        default: fail("no phase"); return
        }
        st("app quits", ticks: 0, expect: phase == "tripped" ? [] : ["disablesleep 0", "idle assertion OFF"]) { engine.shutdown() }
        verifyRestored("after quit")
    }

    // MARK: Crash at every phase, then relaunch

    func crashChild(_ phase: String) {
        Sim.headless = true
        printLines = false
        switch phase {
        case "engaged", "closed":
            bootS()
            st("Go AFK + close") { engine.start(); if phase == "closed" { hold("cli-x", agent: "cli", expires: 3600) }; closeLid() }
        case "music":
            bootS()
            st("Go AFK + close") { engine.start(); closeLid() }
            st("music") { Sim.set("audio", "playing") }
        case "thermal":
            Sim.set("battery", "90 ac")
            bootS()
            st("Go AFK + close") { engine.start(); closeLid() }
            st("serious") { Sim.set("thermal", "serious") }
            st("unplugged", ticks: 3) { Sim.set("battery", "85 battery") }
        case "grace":
            bootS()
            st("hold + close") { hold("claude-s1"); closeLid() }
            st("grace", ticks: 10) { dropHold("claude-s1") }
        case "tripped":
            bootS()
            st("Go AFK + close") { engine.start(); closeLid() }
            st("trip") { Sim.set("battery", "14 battery") }
        case "lpm-preset":
            bootS()
            st("Go AFK + close on battery") { engine.start(); closeLid() }
            st("charger in", ticks: 3) { Sim.set("battery", "81 ac") }
        case "releasefail":
            bootS()
            st("Go AFK") { engine.start() }
            st("rule gone, Stop") { Sim.set("setup", "no"); engine.stop() }
        default: break
        }
        print("  (child exits without shutdown)")
        exit(0)
    }

    func crashParent(_ phase: String) {
        if phase == "lpm-preset" { Sim.set("pmset-lowpowermode-c", "1") }
        let before = snapshot()
        configure()
        let status = spawnSelf("stress-crashchild-\(phase)")
        check(status == 0, "child ran (status \(status))")
        print("  after crash: disablesleep=\(Sim.value("pmset-disablesleep") ?? "-") muted=\(Sim.value("muted") ?? "-") b=\(Sim.value("pmset-lowpowermode-b") ?? "-") c=\(Sim.value("pmset-lowpowermode-c") ?? "-") paused=\(FileManager.default.fileExists(atPath: ChatPauser.file.path))")
        baseline = before
        Sim.clockOffset = 0
        logOffset = readLog().count
        if phase == "closed" {
            truthOpen = false
            Sim.set("lid", "closed"); Sim.set("idle", "600")
            st("relaunch with the lid still closed, hold pending", ticks: 0,
               expect: ["disablesleep 0", "log: Restored normal lid sleep", "SIGCONT chat apps", "lowpowermode 0", "unmute",
                        "disablesleep 1", "lock screen", "mute"]) {
                Sim.headless = true; engine.boot()
            }
            st("next ticks", ticks: 30, forbid: ["lock screen", "] mute", "pmset sleepnow", "disablesleep"])
            endAll()
            return
        }
        openLid(idle: "1")
        Sim.set("audio", "silent")   // the music that was playing at the crash is over
        if phase == "releasefail" {
            st("relaunch, rule still gone", ticks: 0) { Sim.headless = true; engine.boot() }
            let lied = readLog().contains { $0.contains("log: Restored normal lid sleep") } && Sim.value("pmset-disablesleep") == "1"
            check(!lied, "no 'Restored normal lid sleep' log when disablesleep 0 failed (disablesleep=\(Sim.value("pmset-disablesleep") ?? "-"))")
            st("1 min", ticks: 30)
            st("rule back", ticks: 20) { Sim.set("setup", "yes") }
            verifyRestored("after relaunch")
            return
        }
        st("relaunch (lid open)", ticks: 0) { Sim.headless = true; engine.boot() }
        st("first ticks", ticks: 5, forbid: ["lock screen", "] mute", "pmset sleepnow"])
        verifyRestored("after relaunch")
        endAll()
    }

    // MARK: Clock

    func sClockForward() {
        bootS()
        st("claude hold (no expiry) + close", expect: Self.closeActions) { hold("claude-s1"); closeLid() }
        st("Mac slept anyway; wakes 3 h later (clock +3 h)", ticks: 1, forbid: ["Claude Code started working"]) { Sim.clockOffset += 3 * 3600 }
        check(engine.holds.isEmpty && engine.graceUntil != nil, "stale hold dropped, grace started")
        st("grace", ticks: 62, expect: ["unmute", "disablesleep 0", "pmset sleepnow"])
        st("Go AFK 30m + close", expect: Self.closeActions) { engine.choose(minutes: 30); engine.start(); closeLid() }
        st("clock +3 h", ticks: 1, expect: ["Timer finished", "pmset sleepnow"]) { Sim.clockOffset += 3 * 3600 }
        check(count("notify: Time's up") == 1, "one Time's up")
        st("hold + open lid; clock +5 h while lid open", ticks: 3) { openLid(); hold("cli-x", agent: "cli", expires: 3600); engine.tick(); Sim.clockOffset += 5 * 3600 }
        endAll()
    }

    func sClockBack() {
        bootS()
        st("hold + close", expect: Self.closeActions) { hold("claude-s1"); closeLid() }
        st("hold gone: 2 min grace", ticks: 15) { dropHold("claude-s1") }
        st("wall clock set back 1 h", ticks: 1) { Sim.clockOffset -= 3600 }
        st("3 more minutes", ticks: 90)
        check(!engine.isActive, "grace still ends ~2 min after the drop (active=\(engine.isActive), graceUntil in \(Int(engine.graceUntil?.timeIntervalSince(Clock.now()) ?? -1)) s)")
        st("stop grace for the next part", ticks: 2) { engine.agentMode = false; engine.agentMode = true }
        st("Go AFK + close", expect: Self.closeActions) { engine.start(); closeLid() }
        st("wall clock set back 1 h", ticks: 1) { Sim.clockOffset -= 3600 }
        let before = count("displaysleepnow")
        st("5 min closed", ticks: 150)
        let pushes = count("displaysleepnow") - before
        check(pushes >= 8, "display kept dark every ~30 s after the clock change (got \(pushes) pushes in 5 min)")
        endAll()
    }

    // MARK: Lid sensor rules

    func sStaleRearm() {
        Sim.set("lid", "closed")   // stale Yes; the lid is really open
        truthOpen = true; Sim.set("idle", "1")
        bootS()
        st("Go AFK while typing", ticks: 10, forbid: ["lock screen", "] mute"]) { engine.start() }
        st("Stop", forbid: ["pmset sleepnow"]) { engine.stop() }
        st("user starts a YouTube video and sits back (idle 20 s)", ticks: 2) { Sim.set("audio", "playing"); Sim.set("idle", "20") }
        st("still watching, idle 70 s", ticks: 5, forbid: ["lock screen", "SIGSTOP", "displaysleepnow"]) { Sim.set("idle", "70") }
        st("video ends (idle 80 s)", forbid: ["pmset sleepnow"]) { Sim.set("audio", "silent"); Sim.set("idle", "80") }
        endAll()
    }

    func sHidUnderLid() {
        bootS()
        st("Go AFK + real close", expect: Self.closeActions) { engine.start(); closeLid() }
        st("10 min closed", ticks: 20, every: 30)
        st("Bluetooth keyboard input under the lid (no monitor)", expect: ["unmute"], forbid: ["pmset sleepnow"]) { Sim.set("idle", "1"); truthOpen = true }
        truthOpen = false   // the lid is still physically closed
        st("idle again for 10 min", ticks: 20, every: 30, forbid: ["pmset sleepnow"]) { Sim.set("idle", "600") }
        check(engine.lidEngaged, "back to closed-away after the input stops (engaged=\(engine.lidEngaged), display pushes stop, sound stays on)")
        st("work ends, lid still physically closed", ticks: 3, expect: ["disablesleep 0", "pmset sleepnow"]) { engine.stop() }
        endAll()
    }

    // MARK: Low Power

    func sUnplugLpm() {
        Sim.set("battery", "95 ac")
        bootS()
        st("Go AFK + close on AC", expect: ["lock screen"], forbid: ["lowpowermode"]) { engine.start(); closeLid() }
        st("charger unplugged under the lid", ticks: 5, expect: ["sudo pmset -b lowpowermode 1"]) { Sim.set("battery", "94 battery") }
        endAll()
    }

    func sLpmExact() {
        Sim.set("pmset-lowpowermode-b", "1")
        bootS()
        st("user's battery LPM already on: close on battery", expect: ["lock screen"], forbid: ["lowpowermode"]) { engine.start(); closeLid() }
        st("serious heat", ticks: 3, forbid: ["lowpowermode"]) { Sim.set("thermal", "serious") }
        st("charger in under the lid, still serious", ticks: 3, expect: ["sudo pmset -c lowpowermode 1"]) { Sim.set("battery", "80 ac") }
        st("unplugged again", ticks: 3, forbid: ["-b lowpowermode"]) { Sim.set("battery", "79 battery") }
        st("open", expect: ["sudo pmset -c lowpowermode 0"], forbid: ["-b lowpowermode"]) { openLid() }
        check(Sim.value("pmset-lowpowermode-b") == "1" && Sim.value("pmset-lowpowermode-c") == "0", "battery LPM (user's) kept, charger LPM (ours) undone")
        endAll()
    }

    func sAutoPower() {
        Sim.set("battery", "70 battery")
        bootS(["autoOnPower": true])
        st("charger connected: trigger", expect: ["disablesleep 1"]) { Sim.set("battery", "70 ac") }
        st("close", expect: ["lock screen", "mute"]) { closeLid() }
        st("unplugged", expect: ["disablesleep 0", "pmset sleepnow"]) { Sim.set("battery", "70 battery") }
        st("replugged under the lid", ticks: 2, expect: ["disablesleep 1", "lock screen"]) { Sim.set("battery", "70 ac") }
        st("unplug for the end", ticks: 2) { Sim.set("battery", "70 battery") }
        endAll()
    }

    func sEventsClosed() {
        bootS()
        st("hold + close", expect: Self.closeActions) { hold("claude-s1"); closeLid() }
        st("waiting event", expect: ["notify: Claude Code needs you"]) {
            FileManager.default.createFile(atPath: Paths.events.appendingPathComponent("\(Int(Clock.now().timeIntervalSince1970))2-claude-waiting").path, contents: Data())
        }
        st("5 min", ticks: 150)
        st("turn ends", ticks: 61, expect: ["notify: Claude Code finished", "notify: While you were away", "pmset sleepnow"]) { dropHold("claude-s1") }
        check(readLog().contains { $0.contains("While you were away") && $0.contains("1 agent turn") }, "summary counts the finished turn")
        endAll()
    }

    // MARK: Watchdog

    /// The real watchdog with every command that touches the system replaced by
    /// a logger (sudo/pmset, osascript, kill), so its decisions can be checked.
    func sWatchdog() {
        configure(); boot()
        let fm = FileManager.default
        let wd = Sim.dir.appendingPathComponent("wd")
        try? fm.createDirectory(at: wd, withIntermediateDirectories: true)
        let fake = wd.appendingPathComponent("fake.sh")
        let log = wd.appendingPathComponent("log")
        try? """
        #!/bin/sh
        echo "$*" >> "\(log.path)"
        case "$1" in sudo) [ -f "\(wd.path)/sudo-fails" ] && exit 1 ;; esac
        exit 0
        """.write(to: fake, atomically: true, encoding: .utf8)
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        var text = Scripts.watchdog
        text = text.replacingOccurrences(of: "/bin/ps -U \"$(/usr/bin/id -u)\" -o args=", with: "cat \"\(wd.path)/ps\"")
        text = text.replacingOccurrences(of: "xargs kill -CONT", with: "xargs \"\(fake.path)\" kill-CONT")
        text = text.replacingOccurrences(of: "/usr/bin/sudo -n", with: "\"\(fake.path)\" sudo")
        text = text.replacingOccurrences(of: "/usr/bin/osascript", with: "\"\(fake.path)\" osascript")
        let dangerous = ["/usr/bin/sudo", "/usr/bin/osascript", "/bin/ps", " kill ", "xargs kill"]
        guard !dangerous.contains(where: { text.contains($0) }) else { fail("watchdog substitution incomplete; not running it"); return }
        let script = wd.appendingPathComponent("watchdog.sh")
        try? text.write(to: script, atomically: true, encoding: .utf8)

        func scenario(_ label: String, ps: String, sudoFails: Bool = false) -> (log: String, left: [String]) {
            try? fm.removeItem(at: log)
            try? ps.write(to: wd.appendingPathComponent("ps"), atomically: true, encoding: .utf8)
            if sudoFails { fm.createFile(atPath: wd.appendingPathComponent("sudo-fails").path, contents: Data()) }
            else { try? fm.removeItem(at: wd.appendingPathComponent("sudo-fails")) }
            Paths.ensure()
            for f in [Paths.lidFlag, Paths.muteFlag] { Paths.touch(f) }
            try? "b".write(to: Paths.lowPowerFlag, atomically: true, encoding: .utf8)
            try? "123\n456".write(to: ChatPauser.file, atomically: true, encoding: .utf8)
            _ = self.script(script, [])
            let out = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
            let left = ((try? fm.contentsOfDirectory(atPath: Paths.state.path)) ?? []).sorted()
            print("  \(label): actions=\(out.split(separator: "\n")) left=\(left)")
            return (out, left)
        }
        let app = "/Applications/AFK Pug.app/Contents/MacOS/AFKPug\n"
        let mcp = "/Applications/AFK Pug.app/Contents/MacOS/AFKPug --mcp\n"
        var r = scenario("app running", ps: app + mcp)
        check(r.log.isEmpty && r.left.count == 4, "app running: watchdog does nothing")
        r = scenario("only --mcp servers", ps: mcp + mcp)
        check(r.log.contains("disablesleep 0") && r.log.contains("kill-CONT 123 456") && r.log.contains("-b lowpowermode 0")
              && r.log.contains("osascript") && r.left.isEmpty, "app gone: everything restored")
        r = scenario("app gone, sudo failing", ps: "", sudoFails: true)
        check(r.left.contains("lid-override"), "lid flag kept for the next try when sudo fails")
        check(r.left.contains("lowpower-restore"), "low power flag kept for the next try when sudo fails (left \(r.left))")
        for f in [Paths.lidFlag, Paths.muteFlag, Paths.lowPowerFlag, ChatPauser.file] { try? fm.removeItem(at: f) }
    }

    // MARK: More

    func sHidBattery() {
        bootS()
        st("12 h CLI hold + real close", expect: Self.closeActions) { hold("cli-long", agent: "cli", expires: 12 * 3600); closeLid() }
        st("10 min closed", ticks: 20, every: 30)
        st("a Bluetooth mouse on the desk is bumped", expect: ["unmute"]) { Sim.set("idle", "1"); truthOpen = true }
        truthOpen = false
        st("nobody there for 2 h", ticks: 120, every: 60) { Sim.set("idle", "7200") }
        st("battery hits the floor, lid physically closed", ticks: 2, expect: ["notify: Battery low", "disablesleep 0", "pmset sleepnow"]) { Sim.set("battery", "15 battery") }
        st("plug in for the end", ticks: 2) { Sim.set("battery", "15 ac") }
        endAll()
    }

    func sProcsLinger() {
        bootS()
        let busy = "  700     1  40.0 /opt/homebrew/bin/codex\n"
        let idle = "  700     1   0.1 /opt/homebrew/bin/codex\n"
        st("codex busy", ticks: 3, expect: ["log: Codex started working", "disablesleep 1"]) { Sim.set("procs", busy) }
        st("close", expect: Self.closeActions) { closeLid() }
        for i in 0..<10 {
            st("codex thinks (idle 20 s) #\(i)", ticks: 10, forbid: ["pmset sleepnow", "unmute", "started working"]) { Sim.set("procs", idle) }
            st("codex busy 10 s #\(i)", ticks: 5, forbid: ["pmset sleepnow", "unmute", "started working"]) { Sim.set("procs", busy) }
        }
        st("codex idle for good: 30 s linger + 2 min grace", ticks: 85, forbid: ["Codex started working"]) { Sim.set("procs", idle) }
        check(!engine.isActive, "asleep after linger + grace")
        st("codex exits", ticks: 2) { Sim.set("procs", nil) }
        endAll()
    }

    func sRemoveSetupClosed() {
        bootS()
        st("Go AFK + close", expect: Self.closeActions) { engine.start(); closeLid() }
        st("permission removed (remote session)", ticks: 2, expect: ["disablesleep 0", "remove sudoers", "unmute", "pmset sleepnow"]) { engine.removeSetup() }
        st("30 s", ticks: 15, forbid: ["lock screen", "] mute", "disablesleep 1", "pmset sleepnow"])
        st("set up again (remote session)", ticks: 2, expect: ["install sudoers", "disablesleep 1", "lock screen"]) { engine.runSetup() }
        endAll()
    }

    func sSoak() {
        printLines = false
        bootS()
        st("12 h CLI hold + close", expect: Self.closeActions) { hold("cli-long", agent: "cli", expires: 12 * 3600); closeLid() }
        let start = readLog().count
        st("8 h closed", ticks: 2880, every: 10)
        let effects = readLog().dropFirst(start).map(effectText).filter(isEffect)
        var counts: [String: Int] = [:]
        for e in effects { counts[e, default: 0] += 1 }
        print("  side effects in 8 h: \(counts)")
        check(Set(counts.keys).subtracting(["pmset displaysleepnow"]).isEmpty, "only display pushes repeat")
        check((counts["pmset displaysleepnow"] ?? 0) <= 8 * 3600 / 30 + 1, "display push at most every 30 s (got \(counts["pmset displaysleepnow"] ?? 0))")
        printLines = true
        endAll()
    }
}

// MARK: - Native agent integrations (Codex, Gemini CLI, Cursor, Claude plugin, usage limit)

extension Runner {
    /// Hook commands per event, for both shapes: nested groups (Claude, Gemini,
    /// Codex) and Cursor's flat list.
    func hookCommands(_ url: URL) -> [String: [String]] {
        let json = (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let hooks = json["hooks"] as? [String: Any] ?? [:]
        return hooks.compactMapValues { value -> [String]? in
            guard let list = value as? [[String: Any]] else { return nil }
            return list.flatMap { entry -> [String] in
                if let inner = entry["hooks"] as? [[String: Any]] { return inner.compactMap { $0["command"] as? String } }
                return [entry["command"] as? String].compactMap { $0 }
            }
        }
    }

    func ours(_ commands: [String]?) -> [String] { (commands ?? []).filter { $0.contains(ConfigFile.marker) } }

    /// The parts every integration shares: install twice through a symlink, one
    /// entry per event, the user's config kept, first backup kept, upgrade of an
    /// older install, uninstall twice, read-only file refused.
    func integrationBasics(_ item: AgentIntegration, url: URL, seed: String, events: [(event: String, action: String)],
                           old: String, keep: (String) -> Bool) {
        let fm = FileManager.default
        let target = Paths.root.appendingPathComponent("dotfiles/\(item.id)-\(url.lastPathComponent)")
        try? fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? seed.write(to: target, atomically: true, encoding: .utf8)
        try? fm.removeItem(at: url)
        try? fm.createSymbolicLink(at: url, withDestinationURL: target)
        check(item.isAvailable() && !item.isConnected(), "\(item.name): available, not connected yet")

        do { try item.connect(); try item.connect() } catch { fail("\(item.name) connect threw \(error)") }
        let installed = hookCommands(url)
        check((try? fm.destinationOfSymbolicLink(atPath: url.path)) != nil, "config is still a symlink")
        for (event, action) in events {
            let mine = ours(installed[event])
            check(mine.count == 1 && mine[0].contains(" \(action) \(item.id)"), "\(event) -> \(action), exactly once (got \(mine))")
        }
        let total = installed.values.reduce(0) { $0 + ours($1).count }
        check(total == events.count, "no stray entries (\(total) of ours, want \(events.count))")
        let text = (try? String(contentsOf: target, encoding: .utf8)) ?? ""
        check(keep(text), "user's other config kept after install")
        check(item.isConnected() && !item.needsUpgrade(), "connected, no upgrade needed")
        let backup = url.appendingPathExtension("afkpug-backup")
        check((try? String(contentsOf: backup, encoding: .utf8)) == seed, "first backup is the user's original file")

        // An older AFK Pug: an event that's gone, one missing, a different command.
        try? old.write(to: target, atomically: true, encoding: .utf8)
        check(item.isConnected() && item.needsUpgrade(), "older install needs an upgrade")
        do { try item.connect() } catch { fail("upgrade threw \(error)") }
        let upgraded = hookCommands(url)
        check(!item.needsUpgrade() && upgraded.values.reduce(0) { $0 + ours($1).count } == events.count, "upgrade leaves exactly one entry per event")
        check((try? String(contentsOf: backup, encoding: .utf8)) == seed, "backup still the original after more writes")

        do { try item.disconnect(); try item.disconnect() } catch { fail("\(item.name) disconnect threw \(error)") }
        let removed = (try? String(contentsOf: target, encoding: .utf8)) ?? ""
        check(!removed.contains(ConfigFile.marker) && !item.isConnected(), "disconnect removes every entry")
        check(keep(removed), "disconnect keeps the user's other config")

        // Read-only: reported, never replaced.
        try? fm.setAttributes([.posixPermissions: 0o444], ofItemAtPath: target.path)
        var threw = false
        do { try item.connect() } catch { threw = true; print("  read-only error: \(error.localizedDescription)") }
        check(threw && (try? String(contentsOf: target, encoding: .utf8)) == removed, "read-only config: error, file untouched")
        try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: target.path)
        do { try item.connect() } catch { fail("reconnect threw \(error)") }
    }

    /// Runs the installed command for `event` with `stdin`, like the agent would.
    @discardableResult
    func fire(_ url: URL, _ event: String, _ stdin: String) -> String {
        guard let command = ours(hookCommands(url)[event]).first else { fail("no hook for \(event)"); return "" }
        let result = shell(command, stdin: stdin)
        if result.status != 0 { fail("\(event) hook exited \(result.status)") }
        if result.seconds > 2 { fail("\(event) hook took \(result.seconds) s") }
        return result.output
    }

    func holdJSON(_ id: String) -> [String: Any]? {
        (try? Data(contentsOf: Paths.holds.appendingPathComponent(id))).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    func exists(_ id: String) -> Bool { FileManager.default.fileExists(atPath: Paths.holds.appendingPathComponent(id).path) }

    /// A connected agent with working hooks isn't also found by process.
    func noDoubleHold(_ display: String, procs: String, holdId: String) {
        step("\(display) process busy while its hook hold exists", ticks: 3) { Sim.set("procs", procs) }
        let names = engine.holds.map(\.id)
        check(names.contains(holdId) && !names.contains { $0.hasPrefix("proc-") }, "only the hook hold counts, no process hold (got \(names))")
        Sim.set("procs", nil)
    }

    func codexHooks() {
        configure(); boot()
        let url = CodexHooks.file.url
        let seed = #"{"hooks":{"PostToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"my-linter"}]}],"Stop":[{"hooks":[{"type":"command","command":"say done"}]}]}}"#
        let cmd = ConfigFile.hookCommand
        let old = #"{"hooks":{"PostToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"my-linter"}]}],"Stop":[{"hooks":[{"type":"command","command":"say done"}]},{"hooks":[{"type":"command","command":"\#(cmd("stop", "codex"))"}]}],"Notification":[{"hooks":[{"type":"command","command":"\#(cmd("wait", "codex"))"}]}],"UserPromptSubmit":[{"hooks":[{"type":"command","command":"/old/path/bin/afkpug-hook start codex"}]}]}}"#
        integrationBasics(AgentIntegrations.codex, url: url, seed: seed, events: CodexHooks.events, old: old) {
            $0.contains("my-linter") && $0.contains("say done") && $0.contains("\"matcher\" : \"Bash\"") || ($0.contains("my-linter") && $0.contains("say done") && $0.contains("Bash"))
        }
        let json = (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let end = ((json?["hooks"] as? [String: Any])?["SessionEnd"] as? [[String: Any]])?.first?["hooks"] as? [[String: Any]]
        check((end?.first?["timeout"] as? Int) == 3, "SessionEnd timeout within Codex's 3 s cap")

        // Realistic Codex stdin (snake_case, session_id is the thread id).
        let base = #""session_id":"thr_7f3a","transcript_path":"/Users/u/.codex/sessions/2026/11/05/rollout.jsonl","cwd":"/Users/u/app","model":"gpt-5.5-codex","permission_mode":"default""#
        engine.refreshIntegrations()
        step("UserPromptSubmit", expect: ["log: Codex started working", "disablesleep 1"]) {
            let out = fire(url, "UserPromptSubmit", #"{\#(base),"hook_event_name":"UserPromptSubmit","turn_id":"t1","prompt":"fix the session_id bug"}"#)
            check(out.isEmpty, "no stdout (it would become developer context)")
        }
        check(exists("codex-thr_7f3a"), "hold named after session_id")
        step("PreToolUse / PostToolUse touch", forbid: ["finished"]) {
            fire(url, "PreToolUse", #"{\#(base),"hook_event_name":"PreToolUse","turn_id":"t1","tool_name":"Bash","tool_use_id":"c1","tool_input":{"command":"echo {\"session_id\":\"evil\"}"}}"#)
            fire(url, "PostToolUse", #"{\#(base),"hook_event_name":"PostToolUse","turn_id":"t1","tool_name":"Bash","tool_use_id":"c1","tool_input":{"command":"ls"},"tool_response":"ok"}"#)
        }
        check(exists("codex-thr_7f3a") && !exists("codex-evil"), "first session_id wins over tool_input")
        noDoubleHold("Codex", procs: "  \(getpid())     1   0.4 /bin/zsh\n  9100 \(getpid())  60.0 node /opt/homebrew/bin/codex\n", holdId: "codex-thr_7f3a")
        step("PermissionRequest: waiting, hold kept", expect: ["notify: Codex needs you"]) {
            fire(url, "PermissionRequest", #"{\#(base),"hook_event_name":"PermissionRequest","turn_id":"t1","tool_name":"Bash","tool_input":{"command":"rm -rf build"}}"#)
        }
        check(exists("codex-thr_7f3a"), "hold survives PermissionRequest")
        step("Stop (finished after 10 s)", ticks: 6, expect: ["log: Codex finished"]) {
            fire(url, "Stop", #"{\#(base),"hook_event_name":"Stop","turn_id":"t1","stop_hook_active":false,"last_assistant_message":"Done."}"#)
        }
        check(!exists("codex-thr_7f3a"), "Stop drops the hold")
        step("Esc: Interrupt releases silently", ticks: 6, forbid: ["finished"]) {
            fire(url, "UserPromptSubmit", #"{\#(base),"hook_event_name":"UserPromptSubmit","turn_id":"t2","prompt":"again"}"#)
            fire(url, "Interrupt", #"{\#(base),"hook_event_name":"Interrupt","turn_id":"t2"}"#)
        }
        check(!exists("codex-thr_7f3a"), "Interrupt drops the hold")
        step("disconnected: process detection is back", ticks: 3, expect: ["log: Codex started working"]) {
            try? AgentIntegrations.codex.disconnect(); engine.refreshIntegrations()
            Sim.set("procs", "  9100 1  60.0 node /opt/homebrew/bin/codex\n")
        }
    }

    func geminiHooks() {
        configure(); boot()
        let url = GeminiHooks.file.url
        let seed = #"{"general":{"vimMode":true},"hooksConfig":{"enabled":true},"hooks":{"BeforeTool":[{"matcher":"write_file|replace","hooks":[{"name":"security-check","type":"command","command":"$GEMINI_PROJECT_DIR/.gemini/hooks/security.sh","timeout":5000}]}]}}"#
        let old = #"{"general":{"vimMode":true},"hooksConfig":{"enabled":true},"hooks":{"BeforeTool":[{"matcher":"write_file|replace","hooks":[{"name":"security-check","type":"command","command":"$GEMINI_PROJECT_DIR/.gemini/hooks/security.sh","timeout":5000}]}],"AfterAgent":[{"hooks":[{"type":"command","command":"\#(ConfigFile.hookCommand("done", "gemini"))"}]}]}}"#
        integrationBasics(AgentIntegrations.gemini, url: url, seed: seed, events: GeminiHooks.events, old: old) {
            $0.contains("security-check") && $0.contains("vimMode") && $0.contains("hooksConfig")
        }
        let json = (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let entry = (((json?["hooks"] as? [String: Any])?["BeforeAgent"] as? [[String: Any]])?.first?["hooks"] as? [[String: Any]])?.first
        check((entry?["timeout"] as? Int) == 5000 && (entry?["name"] as? String) == "afkpug-beforeagent", "Gemini entries carry a name and a ms timeout")

        // settings.json with comments (JSONC): refuse rather than drop the comments.
        let target = url.resolvingSymlinksInPath()
        let jsonc = "{\n  // my settings\n  \"general\": {\"vimMode\": true}\n}\n"
        let saved = (try? String(contentsOf: target, encoding: .utf8)) ?? ""
        try? jsonc.write(to: target, atomically: true, encoding: .utf8)
        var threw = false
        do { try AgentIntegrations.gemini.connect() } catch { threw = true; print("  JSONC error: \(error.localizedDescription)") }
        check(threw && (try? String(contentsOf: target, encoding: .utf8)) == jsonc, "settings.json with comments: error, file untouched")
        try? saved.write(to: target, atomically: true, encoding: .utf8)

        let base = #""session_id":"8d1c-gem","transcript_path":"/Users/u/.gemini/tmp/chats/session.json","cwd":"/Users/u/app","timestamp":"2026-11-05T09:30:00.000Z""#
        engine.refreshIntegrations()
        step("BeforeAgent", expect: ["log: Gemini CLI started working", "disablesleep 1"]) {
            check(fire(url, "BeforeAgent", #"{\#(base),"hook_event_name":"BeforeAgent","prompt":"add tests"}"#).isEmpty, "no stdout (empty = allow, unchanged)")
        }
        check(exists("gemini-8d1c-gem"), "hold named after session_id")
        step("BeforeTool / AfterTool touch", forbid: ["finished"]) {
            check(fire(url, "BeforeTool", #"{\#(base),"hook_event_name":"BeforeTool","tool_name":"run_shell_command","tool_input":{"command":"npm test"},"mcp_context":null,"original_request_name":"run_shell_command"}"#).isEmpty, "BeforeTool prints nothing")
            fire(url, "AfterTool", #"{\#(base),"hook_event_name":"AfterTool","tool_name":"run_shell_command","tool_input":{"command":"npm test"},"tool_response":{"llmContent":"ok","returnDisplay":"ok"}}"#)
        }
        noDoubleHold("Gemini CLI", procs: "  9200 1  40.0 node /opt/homebrew/lib/node_modules/@google/gemini-cli/dist/index.js\n", holdId: "gemini-8d1c-gem")
        step("Notification ToolPermission", expect: ["notify: Gemini CLI needs you"]) {
            fire(url, "Notification", #"{\#(base),"hook_event_name":"Notification","notification_type":"ToolPermission","message":"Allow run_shell_command?","details":{}}"#)
        }
        step("AfterAgent (finished after 10 s)", ticks: 6, expect: ["log: Gemini CLI finished"]) {
            check(fire(url, "AfterAgent", #"{\#(base),"hook_event_name":"AfterAgent","prompt":"add tests","prompt_response":"Added 3 tests.","stop_hook_active":false}"#).isEmpty, "AfterAgent prints nothing (exit 2 would force a retry)")
        }
        check(!exists("gemini-8d1c-gem"), "AfterAgent drops the hold")
        step("SessionEnd drops a leftover hold", forbid: ["finished"]) {
            fire(url, "BeforeAgent", #"{\#(base),"hook_event_name":"BeforeAgent","prompt":"x"}"#)
            fire(url, "SessionEnd", #"{\#(base),"hook_event_name":"SessionEnd","reason":"exit"}"#)
        }
        check(!exists("gemini-8d1c-gem"), "SessionEnd drops the hold")
    }

    func cursorHooks() {
        configure(); boot()
        let url = CursorHooks.configURL
        let seed = #"{"version":1,"hooks":{"beforeShellExecution":[{"command":"./hooks/block-git.sh"}],"stop":[{"command":"./hooks/audit.sh","timeout":5}]}}"#
        let oldCmd = CursorHooks.command("afterFileEdit", "touch")
        let old = #"{"version":1,"hooks":{"beforeShellExecution":[{"command":"./hooks/block-git.sh"}],"stop":[{"command":"./hooks/audit.sh","timeout":5}],"afterFileEdit":[{"command":"\#(oldCmd.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))"}],"beforeShellExecution2":[{"command":"/x/bin/afkpug-hook touch cursor"}]}}"#
        integrationBasics(AgentIntegrations.cursor, url: url, seed: seed, events: CursorHooks.events, old: old) {
            $0.contains("block-git.sh") && $0.contains("audit.sh") && $0.contains("\"version\"")
        }
        check(ours(hookCommands(url)["beforeShellExecution"]).isEmpty && ours(hookCommands(url)["preToolUse"]).isEmpty, "no permission hooks of ours (they'd have to answer allow)")

        let base = #""conversation_id":"conv-42","generation_id":"gen-1","model":"claude-4.5-sonnet","model_id":"claude-4.5-sonnet","cursor_version":"2.9.1","workspace_roots":["/Users/u/app"],"user_email":null,"transcript_path":null"#
        engine.refreshIntegrations()
        step("beforeSubmitPrompt", expect: ["log: Cursor started working", "disablesleep 1"]) {
            let out = fire(url, "beforeSubmitPrompt", #"{\#(base),"hook_event_name":"beforeSubmitPrompt","prompt":"refactor","attachments":[]}"#)
            check(out == "{\"continue\":true}\n", "beforeSubmitPrompt answers {\"continue\":true} (got \(out.debugDescription))")
        }
        check(exists("cursor-conv-42"), "hold named after conversation_id")
        step("afterShellExecution / afterFileEdit / postToolUse touch", forbid: ["finished"]) {
            for (event, extra) in [("afterShellExecution", #""command":"npm test","output":"ok","duration":1200,"sandbox":false"#),
                                   ("afterFileEdit", #""file_path":"/Users/u/app/a.ts","edits":[{"old_string":"a","new_string":"b"}]"#),
                                   ("postToolUse", #""tool_name":"Shell","tool_input":{},"tool_use_id":"t1","cwd":"/Users/u/app","tool_output":"ok","duration":5"#)] {
                let out = fire(url, event, #"{\#(base),"hook_event_name":"\#(event)",\#(extra)}"#)
                check(out == "{}\n", "\(event) answers {} (got \(out.debugDescription))")
            }
        }
        noDoubleHold("Cursor Agent", procs: "  9300 1  30.0 cursor-agent\n", holdId: "cursor-conv-42")
        step("stop completed (finished after 10 s)", ticks: 6, expect: ["log: Cursor finished"]) {
            check(fire(url, "stop", #"{\#(base),"hook_event_name":"stop","status":"completed","loop_count":0}"#) == "{}\n", "stop answers {} (no followup_message)")
        }
        step("stop aborted: released silently", ticks: 6, forbid: ["finished", "error"]) {
            fire(url, "beforeSubmitPrompt", #"{\#(base),"hook_event_name":"beforeSubmitPrompt","prompt":"x"}"#)
            fire(url, "stop", #"{\#(base),"hook_event_name":"stop","status":"aborted","loop_count":0}"#)
        }
        check(!exists("cursor-conv-42"), "aborted drops the hold")
        step("stop error: failed event", ticks: 6, expect: ["notify: Cursor stopped with an error"], forbid: ["finished"]) {
            fire(url, "beforeSubmitPrompt", #"{\#(base),"hook_event_name":"beforeSubmitPrompt","prompt":"x"}"#)
            fire(url, "stop", #"{\#(base),"hook_event_name":"stop","status":"error","loop_count":0}"#)
        }
        // Cursor also runs ~/.claude/settings.json hooks: those count as Cursor, same hold.
        step("Claude hook run by Cursor counts as Cursor", expect: ["log: Cursor started working"], forbid: ["Claude Code"]) {
            script(Paths.hookScript, ["start", "claude"], stdin: #"{\#(base),"hook_event_name":"beforeSubmitPrompt","prompt":"x"}"#)
        }
        check(exists("cursor-conv-42") && !exists("claude-conv-42"), "same hold as Cursor's own hooks")
        fire(url, "sessionEnd", #"{\#(base),"hook_event_name":"sessionEnd","session_id":"s-9","reason":"user_close","duration_ms":1000,"final_status":"completed"}"#)
        check(!exists("cursor-conv-42"), "sessionEnd drops the hold")

        // The app (and its script) gone: the hook still answers valid JSON and exits 0.
        let moved = Paths.hookScript.appendingPathExtension("moved")
        try? FileManager.default.moveItem(at: Paths.hookScript, to: moved)
        let out = fire(url, "beforeSubmitPrompt", #"{\#(base),"hook_event_name":"beforeSubmitPrompt","prompt":"x"}"#)
        check(out == "{\"continue\":true}\n", "without the script: still {\"continue\":true}, exit 0")
        try? FileManager.default.moveItem(at: moved, to: Paths.hookScript)
    }

    func claudePlugin() {
        configure(); boot()
        let fm = FileManager.default
        try? fm.createDirectory(at: ClaudeHooks.pluginsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? #"{"model":"opus"}"#.write(to: ClaudeHooks.settingsURL, atomically: true, encoding: .utf8)
        do { try ClaudeHooks.install() } catch { fail("install threw \(error)") }
        check(ClaudeHooks.isInstalled() && !ClaudeHooks.pluginInstalled(), "no plugin: settings.json hooks written")
        let plugins = #"{"version":2,"plugins":{"afk-pug@afk-pug":[{"scope":"user","installPath":"/Users/u/.claude/plugins/cache/afk-pug/afk-pug/0.3.0","version":"0.3.0"}]}}"#
        try? plugins.write(to: ClaudeHooks.pluginsURL, atomically: true, encoding: .utf8)
        check(ClaudeHooks.pluginInstalled(), "plugin detected")
        check(!AgentIntegrations.claude.needsUpgrade(), "no upgrade offered with the plugin")
        do { try AgentIntegrations.claude.connect() } catch { fail("connect threw \(error)") }
        check(!ClaudeHooks.isInstalled() && AgentIntegrations.claude.isConnected(), "plugin installed: settings.json hooks removed, still connected")
        check((try? String(contentsOf: ClaudeHooks.settingsURL, encoding: .utf8))?.contains("opus") == true, "rest of settings.json kept")
        var message = ""
        do { try AgentIntegrations.claude.disconnect() } catch { message = error.localizedDescription }
        check(message.contains("/plugin"), "disconnect explains how to remove the plugin (\(message))")
        try? #"{"model":"opus","enabledPlugins":{"afk-pug@afk-pug":false}}"#.write(to: ClaudeHooks.settingsURL, atomically: true, encoding: .utf8)
        check(!ClaudeHooks.pluginInstalled(), "plugin turned off in enabledPlugins: not counted")
        try? #"{"version":2,"plugins":{"afk-pug@afk-pug":[{"scope":"project","projectPath":"/x"}]}}"#.write(to: ClaudeHooks.pluginsURL, atomically: true, encoding: .utf8)
        try? #"{}"#.write(to: ClaudeHooks.settingsURL, atomically: true, encoding: .utf8)
        check(!ClaudeHooks.pluginInstalled(), "project-scope install only: not counted")

        // The repo's plugin: same events and actions as the settings.json hooks, and its
        // commands work (fail-safe, silent) against the installed script.
        let repo = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let hooksURL = repo.appendingPathComponent("plugin/hooks/hooks.json")
        guard fm.fileExists(atPath: hooksURL.path) else { print("  (plugin/ not found from \(repo.path); run from the repo root to check it)"); return }
        let commands = hookCommands(hooksURL)
        for (event, action) in ClaudeHooks.events {
            let list = commands[event] ?? []
            check(list.count == 1 && list[0].contains("afkpug-hook\" \(action) claude; true"), "plugin \(event) -> \(action) (got \(list))")
        }
        check(Set(commands.keys) == Set(ClaudeHooks.events.map(\.event)), "plugin has no other events")
        let mcp = (try? Data(contentsOf: repo.appendingPathComponent("plugin/.mcp.json"))).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let server = (mcp?["mcpServers"] as? [String: Any])?["afkpug"] as? [String: Any]
        check((server?["command"] as? String) == "/Applications/AFK Pug.app/Contents/MacOS/AFKPug" && (server?["args"] as? [String]) == ["--mcp"], "plugin MCP server runs the app with --mcp")
        let input = #"{"session_id":"plug-1","hook_event_name":"UserPromptSubmit","prompt":"x"}"#
        step("plugin UserPromptSubmit command", expect: ["log: Claude Code started working"]) {
            let r = shell(commands["UserPromptSubmit"]![0], stdin: input)
            check(r.status == 0 && r.output.isEmpty, "silent, exit 0")
        }
        step("plugin Stop command (finished after 10 s)", ticks: 6, expect: ["log: Claude Code finished"]) { shell(commands["Stop"]![0], stdin: input) }
        let moved = Paths.hookScript.appendingPathExtension("moved")
        try? fm.moveItem(at: Paths.hookScript, to: moved)
        let r = shell(commands["UserPromptSubmit"]![0], stdin: input)
        check(r.status == 0 && r.output.isEmpty, "app not installed: plugin hook does nothing, exit 0")
        try? fm.moveItem(at: moved, to: Paths.hookScript)
    }

    /// Claude Code usage limits (StopFailure, error rate_limit): stay awake until the
    /// reset shown in the message, so Claude can continue on its own.
    func usageLimit() {
        configure(["graceMinutes": 2]); boot()
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        func clock(_ date: Date) -> String { df.dateFormat = "h:mma"; return df.string(from: date).lowercased() }
        let base = #""session_id":"lim-1","transcript_path":"/Users/u/.claude/projects/p/lim-1.jsonl","cwd":"/Users/u/app","hook_event_name":"StopFailure""#
        func failure(_ error: String, _ message: String, details: String? = nil) -> String {
            #"{\#(base),"error":"\#(error)",\#(details.map { #""error_details":"\#($0)","# } ?? "")"last_assistant_message":"\#(message)"}"#
        }
        let start = #"{"session_id":"lim-1","hook_event_name":"UserPromptSubmit","prompt":"big refactor"}"#
        func expires() -> TimeInterval? { (holdJSON("claude-lim-1")?["expires"] as? Double).flatMap { $0 > 0 ? $0 : nil } }

        // 1. Session limit, resets in ~2 h.
        let reset = Date().addingTimeInterval(2 * 3600)
        let floor = (reset.timeIntervalSince1970 / 60).rounded(.down) * 60
        step("prompt", expect: ["log: Claude Code started working"]) { script(Paths.hookScript, ["start", "claude"], stdin: start) }
        step("StopFailure: session limit, resets \(clock(reset))", expect: ["notify: Claude Code stopped with an error"], forbid: ["finished"]) {
            script(Paths.hookScript, ["fail", "claude"], stdin: failure("rate_limit", "You've hit your session limit · resets \(clock(reset))", details: "429 Too Many Requests"))
        }
        let json = holdJSON("claude-lim-1")
        print("  hold: \(json ?? [:])")
        check(abs((expires() ?? 0) - (floor + 120)) <= 61, "hold expires at the reset + 2 min (got \(expires() ?? 0), want ~\(floor + 120))")
        check((json?["reason"] as? String) == "usage limit", "reason usage limit")
        check(engine.holds.first?.displayName == tr("%@ · waiting for the usage limit to reset", "Claude Code"), "shown as waiting for the reset (\(engine.holds.first?.displayName ?? "-"))")
        step("close the lid: stays awake through the wait", ticks: 30, every: 60, expect: Self.closeActions, forbid: ["pmset sleepnow", "unmute"]) { Sim.set("lid", "closed") }
        check(engine.isActive && exists("claude-lim-1"), "still awake 30 min into the wait")
        step("battery guard still applies during the wait", expect: ["pmset sleepnow"]) { Sim.set("battery", "10 battery") }
        check(engine.trip != nil, "battery floor trips even with a usage-limit hold")
        Sim.set("battery", "80 battery"); Sim.set("lid", "open")
        step("reset passes with no continuation: hold expires, grace, then sleep", ticks: 3, every: 3600) {}
        check(!exists("claude-lim-1"), "usage-limit hold expired after the reset")

        // 2. Claude continues after the reset: quota_auto_resume_fired re-creates a normal hold.
        script(Paths.hookScript, ["start", "claude"], stdin: start)
        script(Paths.hookScript, ["fail", "claude"], stdin: failure("rate_limit", "You've hit your Opus limit · resets \(clock(reset))"))
        check(expires() != nil, "Opus limit holds too")
        script(Paths.hookScript, ["notify", "claude"], stdin: #"{"session_id":"lim-1","hook_event_name":"Notification","notification_type":"quota_auto_resume_fired","message":"Usage limit reset · Continuing automatically"}"#)
        check(exists("claude-lim-1") && expires() == nil, "auto-resume: normal hold again")
        script(Paths.hookScript, ["fail", "claude"], stdin: failure("rate_limit", "You've hit your session limit · resets \(clock(reset))"))
        script(Paths.hookScript, ["touch", "claude"], stdin: #"{"session_id":"lim-1","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{}}"#)
        check(exists("claude-lim-1") && expires() == nil, "a tool call after the wait turns it back into a normal hold")
        script(Paths.hookScript, ["fail", "claude"], stdin: failure("rate_limit", "You've hit your session limit · resets \(clock(reset))"))
        script(Paths.hookScript, ["notify", "claude"], stdin: #"{"session_id":"lim-1","hook_event_name":"Notification","notification_type":"quota_auto_resume_disabled","message":"x"}"#)
        check(!exists("claude-lim-1"), "auto-continue off / cancelled: hold dropped")

        // 3. Formats and the other cases.
        func outcome(_ payload: String) -> TimeInterval? {
            script(Paths.hookScript, ["start", "claude"], stdin: start)
            script(Paths.hookScript, ["fail", "claude"], stdin: payload)
            let left = exists("claude-lim-1") ? (expires().map { $0 - Date().timeIntervalSince1970 } ?? -1) : nil
            try? FileManager.default.removeItem(at: Paths.holds.appendingPathComponent("claude-lim-1"))
            return left
        }
        let wd = Calendar(identifier: .gregorian).component(.weekday, from: Date())   // 1 = Sunday
        let days = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        let cases: [(String, String, ClosedRange<TimeInterval>?)] = [
            ("weekly limit 3 days away: released", failure("rate_limit", "You've hit your weekly limit · resets \(days[(wd - 1 + 3) % 7]) 12:00am"), nil),
            ("weekly limit later today", failure("rate_limit", "You've hit your weekly limit · resets \(days[wd - 1]) \(clock(Date().addingTimeInterval(3 * 3600)))"), (3 * 3600 - 60)...(3 * 3600 + 180)),
            ("time already passed today = tomorrow (>6 h): released", failure("rate_limit", "You've hit your session limit · resets \(clock(Date().addingTimeInterval(-3600)))"), nil),
            ("throttle, not a usage limit: released", failure("rate_limit", "API Error: Server is temporarily limiting requests (not your usage limit)"), nil),
            ("rate limit without a reset time: 30 min", failure("rate_limit", "API Error: Rate limit reached", details: "429 Too Many Requests"), (1790)...(1810)),
            ("server error: released", failure("server_error", "API Error: 500 Internal server error"), nil),
            ("authentication failed: released", failure("authentication_failed", "Please run /login"), nil),
            ("gateway spend cap in UTC", failure("rate_limit", "spend limit reached (daily; resets \(utc(Date().addingTimeInterval(4 * 3600))) UTC)"), (4 * 3600 - 60)...(4 * 3600 + 180)),
            ("hour only, 'at'", failure("rate_limit", "Usage limit reached · limit resets at \(hourOnly(Date().addingTimeInterval(5400)))"), 1...(5400 + 180)),
        ]
        for (label, payload, range) in cases {
            let got = outcome(payload)
            if let range { check(got.map { range.contains($0) } == true, "\(label) (expires in \(got.map { Int($0) } ?? -1) s)") }
            else { check(got == nil, "\(label) (got \(got.map { "hold \(Int($0)) s" } ?? "no hold"))") }
        }
        step("events from the failures fire", ticks: 1) {}
    }

    private func utc(_ date: Date) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX"); df.timeZone = TimeZone(identifier: "UTC"); df.dateFormat = "yyyy-MM-dd HH:mm"
        return df.string(from: date)
    }

    /// "4pm": the next full hour after `date`'s hour.
    private func hourOnly(_ date: Date) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX"); df.dateFormat = "ha"
        return df.string(from: date).lowercased()
    }
}
