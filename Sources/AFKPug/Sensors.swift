import Foundation
import IOKit
import IOKit.ps

/// Read-only system state: lid, battery, thermal.
enum Sensors {
    /// True when the MacBook lid is closed.
    static func lidClosed() -> Bool {
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

    static func battery() -> Battery {
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
        ProcessInfo.processInfo.thermalState
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
