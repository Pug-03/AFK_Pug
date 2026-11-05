import Foundation
import AppKit
import IOKit.pwr_mgt

/// Safe simulation mode (`AFKPUG_SIM=1`).
///
/// Nothing that touches power state, audio, the screen lock or other processes
/// runs: every such action is appended to `<dir>/actions.log` instead, and the
/// sensors read fake values from files in `<dir>` when present:
///   lid      = closed | open               (raw AppleClamshellState flag)
///   display  = external | builtin | error  (external monitor attached?)
///   battery  = "<percent> ac|battery" | none
///   thermal  = nominal | fair | serious | critical
///   audio    = playing | silent
///   apps     = comma separated running app names
///   procs    = lines in `ps -Ao pid=,ppid=,pcpu=,args=` format
///   setup    = yes | no                    (sudoers rule installed?)
///   idle     = seconds since the last HID input
///   lid-event = closed | open              (one-shot IOKit clamshell message)
///   claude   = missing                     (no `claude` command for MCP setup)
/// `<dir>` is `$AFKPUG_SIM_DIR` or `~/.afkpug/sim`. All app state (holds,
/// events, flags, scripts) lives under `<dir>/root`, so a real AFK Pug keeps
/// running untouched. Production behaviour is identical when the variable is unset.
enum Sim {
    static let enabled = ProcessInfo.processInfo.environment["AFKPUG_SIM"] == "1"
    static let dir: URL = {
        if let custom = ProcessInfo.processInfo.environment["AFKPUG_SIM_DIR"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".afkpug/sim", isDirectory: true)
    }()
    static var actionLog: URL { dir.appendingPathComponent("actions.log") }
    /// Fake home for agent configs (~/.claude, ~/.codex, ...) and the hook scripts'
    /// $HOME; its .afkpug is a link to `<dir>/root`.
    static var home: URL { dir.appendingPathComponent("home") }
    /// Seconds added to the wall clock, so scenarios can skip ahead.
    nonisolated(unsafe) static var clockOffset: TimeInterval = 0
    /// Set by the headless runner: no timer, hotkey or notification prompt.
    nonisolated(unsafe) static var headless = false

    static func now() -> Date { Date().addingTimeInterval(clockOffset) }

    static func value(_ name: String) -> String? {
        guard enabled, let text = try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func set(_ name: String, _ value: String?) {
        let url = dir.appendingPathComponent(name)
        if let value {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? value.write(to: url, atomically: true, encoding: .utf8)
        } else {
            try? FileManager.default.removeItem(at: url)
        }
    }

    static func record(_ action: String) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let line = String(format: "[t+%5.0fs] ", clockOffset) + action + "\n"
        if let handle = try? FileHandle(forWritingTo: actionLog) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? line.write(to: actionLog, atomically: true, encoding: .utf8)
        }
    }
}

/// Wall clock, shifted in simulation mode.
enum Clock {
    static func now() -> Date { Sim.enabled ? Sim.now() : Date() }
}

/// Everything that changes system power behaviour lives here.
///
/// Lid-closed mode uses `pmset -a disablesleep`, run through a scoped sudoers
/// rule installed once (`/etc/sudoers.d/afkpug`) that allows only the exact
/// pmset commands below. A flag file records that we changed the setting so a
/// crash, quit or reboot can always put it back.
enum PowerControl {
    static let sudoersPath = "/etc/sudoers.d/afkpug"
    /// Low Power Mode is per power source (`-b` battery, `-c` charger), so we
    /// only ever touch the source in use, never `-a` (which would overwrite both).
    static let allowedCommands = [
        "/usr/bin/pmset -a disablesleep 1",
        "/usr/bin/pmset -a disablesleep 0",
        "/usr/bin/pmset -b lowpowermode 1",
        "/usr/bin/pmset -b lowpowermode 0",
        "/usr/bin/pmset -c lowpowermode 1",
        "/usr/bin/pmset -c lowpowermode 0",
    ]

    enum PowerSource: String {
        case battery = "b", ac = "c"
        static var current: PowerSource { Sensors.battery().onAC ? .ac : .battery }
    }

    // MARK: Idle-sleep assertion (lid open)

    private static var assertionID: IOPMAssertionID = 0
    private static var holdingAssertion = false

    static func setIdleAssertion(_ on: Bool) {
        if Sim.enabled {
            if on != holdingAssertion { Sim.record("idle assertion \(on ? "ON" : "OFF")") }
            holdingAssertion = on
            return
        }
        if on, !holdingAssertion {
            var id: IOPMAssertionID = 0
            let result = IOPMAssertionCreateWithName(
                "PreventUserIdleSystemSleep" as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "AFK Pug is keeping your Mac awake" as CFString,
                &id
            )
            if result == kIOReturnSuccess {
                assertionID = id
                holdingAssertion = true
            }
        } else if !on, holdingAssertion {
            IOPMAssertionRelease(assertionID)
            holdingAssertion = false
        }
    }

    // MARK: Lid-closed override

    /// Our rule file must exist (`sudo -n -l` alone also succeeds through any
    /// unrelated NOPASSWD rule) and must already allow the per-source Low Power
    /// commands, so people with the older `-a lowpowermode` rule set up again.
    static var isSetupDone: Bool {
        if Sim.enabled { return Sim.value("setup") != "no" }
        guard FileManager.default.fileExists(atPath: sudoersPath) else { return false }
        return run("/usr/bin/sudo", ["-n", "-l", "/usr/bin/pmset", "-a", "disablesleep", "0"]).status == 0
            && run("/usr/bin/sudo", ["-n", "-l", "/usr/bin/pmset", "-b", "lowpowermode", "0"]).status == 0
    }

    /// Read from the IORegistry (no subprocess), falling back to `pmset -g`.
    static func sleepDisabled() -> Bool {
        if Sim.enabled { return Sim.value("pmset-disablesleep") == "1" }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        if service != 0 {
            defer { IOObjectRelease(service) }
            if let value = IORegistryEntryCreateCFProperty(service, "SleepDisabled" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? Bool {
                return value
            }
        }
        return pmsetValue("SleepDisabled") == 1
    }

    /// Low Power Mode as it applies right now (i.e. for the current source).
    static func lowPowerOn() -> Bool {
        if Sim.enabled { return Sim.value("pmset-lowpowermode-\(PowerSource.current.rawValue)") == "1" }
        return ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    @discardableResult
    static func setSleepDisabled(_ on: Bool) -> Bool {
        if Sim.enabled {
            let ok = Sim.value("setup") != "no"
            Sim.record("sudo pmset -a disablesleep \(on ? 1 : 0)" + (ok ? "" : "  (FAILED: no sudoers rule)"))
            if ok {
                Sim.set("pmset-disablesleep", on ? "1" : "0")
                if on { Paths.touch(Paths.lidFlag) } else { try? FileManager.default.removeItem(at: Paths.lidFlag) }
            }
            return ok
        }
        let ok = run("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "-a", "disablesleep", on ? "1" : "0"]).status == 0
        if ok {
            if on { Paths.touch(Paths.lidFlag) } else { try? FileManager.default.removeItem(at: Paths.lidFlag) }
        }
        return ok
    }

    @discardableResult
    static func setLowPower(_ on: Bool, source: PowerSource) -> Bool {
        if Sim.enabled {
            Sim.record("sudo pmset -\(source.rawValue) lowpowermode \(on ? 1 : 0)")
            Sim.set("pmset-lowpowermode-\(source.rawValue)", on ? "1" : "0")
            return true
        }
        return run("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "-\(source.rawValue)", "lowpowermode", on ? "1" : "0"]).status == 0
    }

    static func displaySleepNow() {
        if Sim.enabled { Sim.record("pmset displaysleepnow"); return }
        run("/usr/bin/pmset", ["displaysleepnow"])
    }

    static func sleepNow() {
        if Sim.enabled { Sim.record("pmset sleepnow"); return }
        run("/usr/bin/pmset", ["sleepnow"])
    }

    // MARK: Audio

    static func isMuted() -> Bool {
        if Sim.enabled { return Sim.value("muted") == "1" }
        return run("/usr/bin/osascript", ["-e", "output muted of (get volume settings)"]).output
            .trimmingCharacters(in: .whitespacesAndNewlines) == "true"
    }

    static func setMuted(_ on: Bool) {
        if Sim.enabled {
            Sim.record(on ? "mute" : "unmute")
            Sim.set("muted", on ? "1" : "0")
            return
        }
        run("/usr/bin/osascript", ["-e", "set volume output muted \(on)"])
    }

    // MARK: One-time setup (admin prompt)

    /// Installs the sudoers rule. Shows the standard macOS admin prompt once.
    enum AdminError: Error, Equatable {
        case cancelled
        case wrongPassword
        case badUser
        case failed(String)

        /// osascript's output for a failed `do shell script ... with administrator privileges`.
        static func from(output: String, status: Int32) -> AdminError {
            let text = output.lowercased()
            // -128 user cancelled, -60006 errAuthorizationCanceled
            if text.contains("-128") || text.contains("-60006") || text.contains("user canceled") || text.contains("user cancelled") {
                return .cancelled
            }
            // -60005 errAuthorizationDenied: wrong password (three times) or not an admin
            if text.contains("-60005") || text.contains("password was incorrect") || text.contains("password is incorrect") {
                return .wrongPassword
            }
            let message = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failed(message.isEmpty ? "exit \(status)" : message)
        }
    }

    /// Installs the sudoers rule with one admin prompt. The rule is written by the
    /// root shell itself into root-owned /etc/sudoers.d, validated, then moved in
    /// place, so no other process can swap the file between check and install.
    /// Blocking (it waits for the password dialog): call it off the main thread.
    nonisolated static func installSudoers() -> Result<Void, AdminError> {
        if Sim.enabled { Sim.record("install sudoers (admin prompt)"); Sim.set("setup", "yes"); return .success(()) }
        let user = NSUserName()
        guard !user.isEmpty, user.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }) else {
            return .failure(.badUser)
        }
        let rule = "\(user) ALL=(root) NOPASSWD: " + allowedCommands.joined(separator: ", ")
        let new = "/etc/sudoers.d/.afkpug.new"
        let shell = "umask 077; rm -f \(new); printf '%s\\n' '\(rule)' > \(new) && chown root:wheel \(new) && chmod 0440 \(new)"
            + " && /usr/sbin/visudo -cf \(new) && mv -f \(new) \(sudoersPath) || { rm -f \(new); exit 1; }"
        return runAsAdmin(shell, prompt: "AFK Pug needs your password once so it can keep your Mac awake with the lid closed.")
    }

    nonisolated static func uninstallSudoers() -> Result<Void, AdminError> {
        if Sim.enabled {
            if sleepDisabled() { setSleepDisabled(false) }
            Sim.record("remove sudoers (admin prompt)"); Sim.set("setup", "no"); return .success(())
        }
        if sleepDisabled() { setSleepDisabled(false) }
        return runAsAdmin("/bin/rm -f \(sudoersPath)", prompt: "AFK Pug will remove its lid-closed permission.")
    }

    /// Runs a shell command as root through the standard macOS admin dialog
    /// (osascript in a child process, so it can run off the main thread).
    nonisolated static func runAsAdmin(_ shell: String, prompt: String) -> Result<Void, AdminError> {
        let escaped = shell.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let source = "do shell script \"\(escaped)\" with administrator privileges with prompt \"\(prompt)\""
        let result = run("/usr/bin/osascript", ["-e", source])
        if result.status == 0 { return .success(()) }
        return .failure(.from(output: result.output, status: result.status))
    }

    // MARK: Helpers

    private static func pmsetValue(_ key: String) -> Int? {
        let out = run("/usr/bin/pmset", ["-g"]).output
        for line in out.split(separator: "\n") {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if parts.count >= 2, parts[0] == key { return Int(parts[1]) }
        }
        return nil
    }

    @discardableResult
    static func run(_ path: String, _ args: [String]) -> (status: Int32, output: String) {
        // Safety net: in simulation nothing is ever executed.
        if Sim.enabled { Sim.record("BLOCKED exec \(path) \(args.joined(separator: " "))"); return (-1, "") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (-1, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

extension PowerControl.AdminError {
    var message: String {
        switch self {
        case .cancelled: return tr("Cancelled. Nothing was changed.")
        case .wrongPassword: return tr("That password didn't work. Use the password of an administrator account on this Mac.")
        case .badUser: return tr("Your account name has characters a permission rule can't use.")
        case .failed(let text): return tr("Couldn't set up the permission: %@", text)
        }
    }
}
