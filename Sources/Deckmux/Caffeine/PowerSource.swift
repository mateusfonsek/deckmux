import Foundation
import IOKit.ps

/// Where the Mac's power comes from, and how much battery is left.
struct PowerSource: Equatable {
    var onBattery: Bool
    /// nil without a battery.
    var percent: Int?

    static func read() -> PowerSource {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return PowerSource(onBattery: false, percent: nil) }
        let providing = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        let onBattery = providing == kIOPSBatteryPowerValue
        let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] ?? []
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let max = description[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            return PowerSource(onBattery: onBattery, percent: current * 100 / max)
        }
        return PowerSource(onBattery: onBattery, percent: nil)
    }
}
