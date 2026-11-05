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
        ("preview-th", "[13] Thai preview after 85 min closed renders, busy Claude hold survives"),
    ]
    /// Old names of the review proofs, kept as aliases.
    static let reviewScenarios = ["review-chat-call", "review-hotkey-trip", "review-agentmode-off", "review-preview", "review-release-fail",
                                  "preview-grace"]

    static func main(_ args: [String]) -> Int32 {
        setvbuf(stdout, nil, _IOLBF, 0)
        guard Sim.enabled else {
            print("Refusing to simulate without AFKPUG_SIM=1 (it would touch real power state).")
            return 2
        }
        let name = args.first ?? "all"
        if name == "all" { return runAll() }
        guard scenarios.contains(where: { $0.name == name }) || reviewScenarios.contains(name) else {
            print("Unknown scenario \(name). Known: all, " + scenarios.map(\.name).joined(separator: ", "))
            return 2
        }
        return Runner(name: name).run()
    }

    /// Each scenario runs in a fresh process, since Engine is a singleton.
    private static func runAll() -> Int32 {
        var failed: [String] = []
        for (name, about) in scenarios {
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
        print("\n" + (failed.isEmpty ? "ALL \(scenarios.count) SCENARIOS PASSED" : "FAILED: " + failed.joined(separator: ", ")))
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
        let home = Sim.dir.appendingPathComponent("home")
        let link = home.appendingPathComponent(".afkpug")
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) == nil {
            try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            try? FileManager.default.createSymbolicLink(at: link, withDestinationURL: Paths.root)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [url.path] + args
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = home.path
        process.environment = env
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output
        let started = Date()
        do { try process.run() } catch { fail("could not run \(url.lastPathComponent)"); return (-1, "", 0) }
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
        if name != "recovery" { resetSandbox() }
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
        case "preview-th", "review-preview": previewTh()
        case "preview-grace": previewGrace()
        default: fail("no scenario")
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
        step("cools to fair: trip clears, nothing restarts (manual was stopped)", forbid: ["disablesleep 1"]) { Sim.set("thermal", "fair") }
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
        step("music stops", expect: ["SIGCONT chat apps", "sudo pmset -b lowpowermode 0", "idle assertion OFF", "disablesleep 0", "pmset sleepnow"],
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
            check(ours.count == 1 && ours[0].hasSuffix(" \(action) claude"), "\(event) -> \(action), exactly once (got \(ours))")
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
        step("Stop", expect: ["log: Claude Code finished"]) { script(Paths.hookScript, ["stop", "claude"], stdin: input) }
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
        step("call ends", expect: ["disablesleep 0", "pmset sleepnow"]) { Sim.set("audio", "silent") }
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
        step("plugged in: trip clears, Go AFK works again", expect: ["log: Awake for 2h"]) { Sim.set("battery", "14 ac"); engine.tick(); engine.start() }
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
        check(spans == ["r0": 720 * 60, "r1": 60, "r2": 30 * 60, "r3": 90 * 60], "1e300 -> 720 min, -5 -> 1, nan -> 30, 90 -> 90 (got \(spans))")
    }

    /// Events written while the app wasn't running are dropped at launch, fresh ones kept.
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
        step("a later event still fires", expect: ["notify: Claude Code finished"]) { dropHold("none") }
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
