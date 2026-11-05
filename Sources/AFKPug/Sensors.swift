import Foundation
import IOKit
import IOKit.ps
import CoreGraphics

/// Read-only system state: lid, battery, thermal.
enum Sensors {
    /// Raw AppleClamshellState. Only a hint: it has been seen reading Yes with
    /// the lid open, so LidSensor never trusts a level, only changes.
    /// IOKit errors read as open.
    static func clamshellFlag() -> Bool {
        if let fake = Sim.value("lid") { return fake == "closed" }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }
        let value = IORegistryEntryCreateCFProperty(service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue()
        return (value as? Bool) ?? false
    }

    struct Battery: Equatable {
        var percent: Int
        var onAC: Bool
        var hasBattery: Bool
    }

    /// True when a non-built-in display is online (clamshell / docked use).
    /// nil when CoreGraphics can't tell, which callers treat as "not away".
    static func externalDisplay() -> Bool? {
        if let fake = Sim.value("display") { return fake == "error" ? nil : fake == "external" }
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count) == .success else { return nil }
        return ids.prefix(Int(count)).contains { CGDisplayIsBuiltin($0) == 0 }
    }

    /// Seconds since the last real keyboard / mouse / trackpad input (hardware
    /// HID only, so events posted by other apps don't count).
    static func idleSeconds() -> TimeInterval {
        if let fake = Sim.value("idle"), let value = TimeInterval(fake) { return value }
        guard let any = CGEventType(rawValue: ~0) else { return .infinity }
        return CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: any)
    }

    static func battery() -> Battery {
        if let fake = Sim.value("battery") {
            if fake == "none" { return Battery(percent: 100, onAC: true, hasBattery: false) }
            let parts = fake.split(separator: " ")
            return Battery(percent: Int(parts.first ?? "") ?? 100, onAC: parts.count > 1 && parts[1] == "ac", hasBattery: true)
        }
        let blob = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let onAC = (IOPSGetProvidingPowerSourceType(blob)?.takeUnretainedValue() as String?) == "AC Power"
        let list = IOPSCopyPowerSourcesList(blob).takeRetainedValue() as [CFTypeRef]
        for source in list {
            guard let desc = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
                  (desc["Type"] as? String) == "InternalBattery",
                  let current = desc["Current Capacity"] as? Int,
                  let max = desc["Max Capacity"] as? Int, max > 0
            else { continue }
            return Battery(percent: current * 100 / max, onAC: onAC, hasBattery: true)
        }
        return Battery(percent: 100, onAC: true, hasBattery: false)
    }

    static func thermal() -> ProcessInfo.ThermalState {
        switch Sim.value("thermal") {
        case "nominal": return .nominal
        case "fair": return .fair
        case "serious": return .serious
        case "critical": return .critical
        default: return ProcessInfo.processInfo.thermalState
        }
    }
}

extension ProcessInfo.ThermalState {
    var label: String {
        switch self {
        case .nominal: return tr("Cool")
        case .fair: return tr("Warm")
        case .serious: return tr("Hot")
        case .critical: return tr("Too hot")
        @unknown default: return tr("Unknown")
        }
    }
}

/// "Lid closed and nobody is here", built from clamshell *changes* plus hysteresis.
///
/// - Closed is entered on a clamshell close edge (IOKit
///   kIOPMMessageClamshellStateChange, or a polled No -> Yes transition).
/// - It is left on an open edge, or on real HID input after the close (with no
///   external display, where typing on a dock keyboard is normal). The display
///   waking under the lid (lock screen lighting up) changes nothing.
/// - A flag that already reads Yes with no edge (app launch, session start, a
///   monitor that went away) only counts once the user has been idle > 60 s;
///   input first disarms that check, so a stale Yes never locks an active user.
/// - An external display keeps it "not away"; after it disappears it has to
///   stay gone for `monitorDebounce` before lid actions may start.
@MainActor
enum LidSensor {
    static let hidInput: TimeInterval = 3
    static let staleIdle: TimeInterval = 60
    static let monitorDebounce: TimeInterval = 15

    private static var closed = false
    private static var closedAt = Date.distantPast
    private static var lastFlag: Bool?
    /// Evaluate a Yes flag that came without an edge.
    private static var staleArmed = true
    private static var lastExternal = Date.distantPast
    private static var externalRecently = false
    private static var notifier: io_object_t = 0
    /// Edges delivered by IOKit between ticks (true = closed).
    nonisolated(unsafe) fileprivate static var pending: [Bool] = []

    /// Call once per tick. Returns true when the lid is closed and nobody is using the Mac.
    static func update(now: Date) -> Bool {
        startNotifications()
        let flag = Sensors.clamshellFlag()
        var edges = pending
        pending.removeAll()
        if let event = Sim.value("lid-event") {
            // One-shot edge, like the IOKit message (sim only).
            edges.append(event == "closed")
            Sim.set("lid-event", nil)
        }
        if let last = lastFlag, last != flag { edges.append(flag) }
        lastFlag = flag
        for edge in edges {
            staleArmed = false
            if edge {
                if !closed { closed = true; closedAt = now }
            } else {
                closed = false
            }
        }
        return evaluate(now: now, flag: flag)
    }

    /// A session just started: re-check a Yes flag that has no edge behind it.
    static func sessionStarted(now: Date) -> Bool {
        staleArmed = true
        return evaluate(now: now, flag: lastFlag ?? Sensors.clamshellFlag())
    }

    private static func evaluate(now: Date, flag: Bool) -> Bool {
        let external = Sensors.externalDisplay()
        if external != false { lastExternal = now }
        let wasExternal = externalRecently
        externalRecently = now.timeIntervalSince(lastExternal) < monitorDebounce
        // The monitor went away for good: a Yes flag needs re-checking.
        if wasExternal, !externalRecently { staleArmed = true }

        let idle = Sensors.idleSeconds()
        let inputAfterClose = idle < hidInput && now.addingTimeInterval(-idle) > closedAt.addingTimeInterval(2)
        if closed, external == false, inputAfterClose {
            closed = false
            staleArmed = false
        }
        if !flag {
            staleArmed = false
        } else if !closed, staleArmed {
            if idle > staleIdle {
                closed = true
                closedAt = now
                staleArmed = false
            } else if idle < hidInput, external == false {
                staleArmed = false
            }
        }
        return closed && !externalRecently
    }

    private static func startNotifications() {
        guard notifier == 0, !Sim.enabled else { return }
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0, let port = IONotificationPortCreate(kIOMainPortDefault) else {
            if root != 0 { IOObjectRelease(root) }
            notifier = 1 // don't retry every tick; polling still sees transitions
            return
        }
        defer { IOObjectRelease(root) }
        IONotificationPortSetDispatchQueue(port, DispatchQueue.main)
        var object: io_object_t = 0
        let result = IOServiceAddInterestNotification(port, root, kIOGeneralInterest, { _, _, type, argument in
            // kIOPMMessageClamshellStateChange = iokit_family_msg(sub_iokit_powermanagement, 0x100)
            guard type == 0xE003_4100 else { return }
            // Bit 0 of the argument is the new clamshell state (kClamshellStateBit).
            LidSensor.pending.append((UInt(bitPattern: argument) & 1) != 0)
        }, nil, &object)
        notifier = result == KERN_SUCCESS ? object : 1
    }
}
