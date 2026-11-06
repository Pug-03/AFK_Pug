import SwiftUI

/// Renders the README screenshots from the real views, driven by fake sensors.
///
///     AFKPUG_SIM=1 AFKPUG_SIM_DIR=$(mktemp -d) AFKPug --render-screen working out.png --lang th
///
/// Run through scripts/screenshots.sh, one process per scene (Engine is a singleton).
/// Refuses to run without `AFKPUG_SIM=1`, so no real power state is touched.
@MainActor
enum Screens {
    static let scenes = ["setup", "idle", "timer", "working", "limit", "grace", "music", "battery", "away", "white", "custom"]

    static func render(_ scene: String, to path: String, language: AppLanguage) -> Int32 {
        guard Sim.enabled else {
            print("Refusing to render without AFKPUG_SIM=1 (it would touch real power state).")
            return 2
        }
        guard scenes.contains(scene) else {
            print("Unknown scene \(scene). Known: " + scenes.joined(separator: ", "))
            return 2
        }

        prepare(scene)
        let engine = Engine.shared
        L10n.language = language
        Sim.headless = true
        engine.boot()
        engine.tick()
        act(scene, engine)
        engine.refreshIntegrations()

        let view = RootView(engine: engine, fitsWindow: false).environment(\.colorScheme, Theme.scheme)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        Main.write(renderer.nsImage, to: path)
        UserDefaults.standard.removePersistentDomain(forName: "com.pug03.afkpug.sim")
        return 0
    }

    /// Sensors and settings, written before Engine.shared exists.
    private static func prepare(_ scene: String) {
        UserDefaults.standard.removePersistentDomain(forName: "com.pug03.afkpug.sim")
        try? FileManager.default.createDirectory(at: Sim.dir, withIntermediateDirectories: true)
        Paths.ensure()
        Sim.set("lid", "open")
        Sim.set("display", "builtin")
        Sim.set("battery", scene == "battery" ? "12 battery" : "86 battery")
        Sim.set("thermal", "nominal")
        Sim.set("audio", scene == "music" ? "playing" : "silent")
        Sim.set("setup", scene == "setup" ? "no" : "yes")
        Sim.set("idle", "600")
        Sim.set("muted", "0")
        Sim.set("pmset-disablesleep", "0")
        Sim.set("pmset-lowpowermode-b", "0")
        Sim.set("pmset-lowpowermode-c", "0")
        if scene == "setup" {
            try? FileManager.default.createDirectory(at: Sim.home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        }
        let defaults: [String: Any] = [
            "agentMode": true, "lidMode": true, "selectedMinutes": 120, "batteryFloor": 15,
            "displayOffOnClose": true, "muteOnClose": true, "lowPowerOnClose": true, "lidOnlyOnPower": false,
            "notifyAgents": true, "graceMinutes": 5, "detectOtherAgents": true, "pauseChatApps": false,
            "lockOnClose": true, "hotkeyEnabled": true, "phoneTopic": "", "autoOnPower": false,
            "autoApps": "", "keepMusic": true, "onboardingVersion": Engine.onboardingVersion,
        ]
        for (key, value) in defaults { Engine.store.set(value, forKey: key) }
        if scene == "white" {
            Engine.store.set(AppearanceMode.light.rawValue, forKey: "appearance")
            Engine.store.set("#4C9AFF", forKey: "accentColor")
        }
        if scene == "custom" {
            Engine.store.set(AppearanceMode.custom.rawValue, forKey: "appearance")
            Engine.store.set("#1B2A4A", forKey: "backgroundColor")
            Engine.store.set("#3CCB7F", forKey: "accentColor")
        }
        Theme.palette = ThemeStore.loadPalette()
    }

    private static func act(_ scene: String, _ engine: Engine) {
        switch scene {
        case "timer":
            engine.start()
            skip(15 * 60, engine)
        case "working", "white", "custom":
            task("claude-demo", cwd: "/Users/me/Code/billing-api", prompt: L10n.isThai ? "แก้เทสต์การชำระเงินที่พัง" : "Fix the failing payment tests",
                 now: #"{"tool":"Edit","target":"/Users/me/Code/billing-api/checkout.ts"}"#)
            task("codex-demo", cwd: "/Users/me/Code/website", prompt: L10n.isThai ? "ย้ายหน้าเว็บไป Astro" : "Move the site to Astro",
                 now: #"{"waiting":1}"#)
            hold("claude-demo", agent: "claude")
            hold("codex-demo", agent: "codex")
            engine.tick()
        case "limit":
            hold("claude-demo", agent: "claude", expires: 3 * 3600, reason: "usage limit")
            engine.tick()
        case "grace":
            hold("claude-demo", agent: "claude")
            engine.tick()
            try? FileManager.default.removeItem(at: Paths.holds.appendingPathComponent("claude-demo"))
            skip(40, engine)
        case "battery":
            hold("claude-demo", agent: "claude")
            engine.tick()
        case "away":
            let now = Clock.now()
            engine.summary = LidSummary(closedAt: now.addingTimeInterval(-(2 * 3600 + 14 * 60)), openedAt: now, startBattery: 97, endBattery: 86,
                                        peakThermal: .nominal, agentsFinished: 3, hadBattery: true)
        default: break
        }
    }

    private static func task(_ id: String, cwd: String, prompt: String, now: String) {
        try? FileManager.default.createDirectory(at: Paths.tasks, withIntermediateDirectories: true)
        let base = (try? JSONSerialization.data(withJSONObject: ["cwd": cwd, "prompt": prompt])) ?? Data()
        try? base.write(to: Paths.tasks.appendingPathComponent(id))
        try? now.write(to: Paths.tasks.appendingPathComponent(id + ".now"), atomically: true, encoding: .utf8)
    }

    private static func skip(_ seconds: TimeInterval, _ engine: Engine) {
        Sim.clockOffset += seconds
        engine.tick()
    }

    private static func hold(_ id: String, agent: String, expires: TimeInterval = 0, reason: String? = nil) {
        let now = Clock.now().timeIntervalSince1970
        var json = "{\"agent\":\"\(agent)\",\"started\":\(Int(now)),\"expires\":\(expires > 0 ? Int(now + expires) : 0),\"pid\":0"
        if let reason { json += ",\"reason\":\"\(reason)\"" }
        try? (json + "}").write(to: Paths.holds.appendingPathComponent(id), atomically: true, encoding: .utf8)
    }
}
