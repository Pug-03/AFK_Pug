import Foundation
import AppKit
import IOKit.pwr_mgt

/// Everything that changes system power behaviour lives here.
///
/// Lid-closed mode uses `pmset -a disablesleep`, run through a scoped sudoers
/// rule installed once (`/etc/sudoers.d/afkpug`) that allows only the exact
/// pmset commands below. A flag file records that we changed the setting so a
/// crash, quit or reboot can always put it back.
enum PowerControl {
    static let sudoersPath = "/etc/sudoers.d/afkpug"
    static let allowedCommands = [
        "/usr/bin/pmset -a disablesleep 1",
        "/usr/bin/pmset -a disablesleep 0",
        "/usr/bin/pmset -a lowpowermode 1",
        "/usr/bin/pmset -a lowpowermode 0",
    ]

    // MARK: Idle-sleep assertion (lid open)

    private static var assertionID: IOPMAssertionID = 0
    private static var holdingAssertion = false

    static func setIdleAssertion(_ on: Bool) {
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

    static var isSetupDone: Bool {
        run("/usr/bin/sudo", ["-n", "-l", "/usr/bin/pmset", "-a", "disablesleep", "0"]).status == 0
    }

    static func sleepDisabled() -> Bool {
        pmsetValue("SleepDisabled") == 1
    }

    static func lowPowerOn() -> Bool {
        pmsetValue("lowpowermode") == 1
    }

    @discardableResult
    static func setSleepDisabled(_ on: Bool) -> Bool {
        let ok = run("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "-a", "disablesleep", on ? "1" : "0"]).status == 0
        if ok {
            if on { Paths.touch(Paths.lidFlag) } else { try? FileManager.default.removeItem(at: Paths.lidFlag) }
        }
        return ok
    }

    @discardableResult
    static func setLowPower(_ on: Bool) -> Bool {
        run("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "-a", "lowpowermode", on ? "1" : "0"]).status == 0
    }

    static func displaySleepNow() { run("/usr/bin/pmset", ["displaysleepnow"]) }
    static func sleepNow() { run("/usr/bin/pmset", ["sleepnow"]) }

    // MARK: Audio

    static func isMuted() -> Bool {
        run("/usr/bin/osascript", ["-e", "output muted of (get volume settings)"]).output
            .trimmingCharacters(in: .whitespacesAndNewlines) == "true"
    }

    static func setMuted(_ on: Bool) {
        run("/usr/bin/osascript", ["-e", "set volume output muted \(on)"])
    }

    // MARK: One-time setup (admin prompt)

    /// Installs the sudoers rule. Shows the standard macOS admin prompt once.
    static func installSudoers() -> Result<Void, Error> {
        let user = NSUserName()
        let rule = "\(user) ALL=(root) NOPASSWD: " + allowedCommands.joined(separator: ", ") + "\n"
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("afkpug-sudoers")
        do { try rule.write(to: tmp, atomically: true, encoding: .utf8) } catch { return .failure(error) }
        let shell = "/usr/sbin/visudo -cf '\(tmp.path)' && /usr/bin/install -m 0440 -o root -g wheel '\(tmp.path)' \(sudoersPath)"
        defer { try? FileManager.default.removeItem(at: tmp) }
        return runAsAdmin(shell, prompt: "AFK Pug needs your password once so it can keep your Mac awake with the lid closed.")
    }

    static func uninstallSudoers() -> Result<Void, Error> {
        if sleepDisabled() { setSleepDisabled(false) }
        return runAsAdmin("/bin/rm -f \(sudoersPath)", prompt: "AFK Pug will remove its lid-closed permission.")
    }

    private static func runAsAdmin(_ shell: String, prompt: String) -> Result<Void, Error> {
        let escaped = shell.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let source = "do shell script \"\(escaped)\" with administrator privileges with prompt \"\(prompt)\""
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            let message = error[NSAppleScript.errorMessage] as? String ?? "Setup was cancelled."
            return .failure(NSError(domain: "AFKPug", code: 1, userInfo: [NSLocalizedDescriptionKey: message]))
        }
        return .success(())
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
