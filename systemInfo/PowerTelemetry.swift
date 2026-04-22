import Foundation
import IOKit
import IOKit.ps

enum PowerMetricKind: String, Codable {
    case systemPower
}

struct PowerTelemetrySnapshot: Equatable {
    let batteryLevelText: String
    let powerSource: String
    let systemPowerText: String
    let systemPowerWatts: Double?
    let chargeRateText: String
    let chargeRateWatts: Double?
    let powerMetricKind: PowerMetricKind?
    let powerMetricSource: String?

    static let unavailable = PowerTelemetrySnapshot(
        batteryLevelText: "—",
        powerSource: "No battery",
        systemPowerText: "—",
        systemPowerWatts: nil,
        chargeRateText: "—",
        chargeRateWatts: nil,
        powerMetricKind: nil,
        powerMetricSource: nil
    )
}

enum PowerTelemetryParser {
    static let systemPowerSourceKey = "AppleSmartBattery/BatteryData.SystemPower"

    static func snapshot(
        powerSourceDescription: [String: Any],
        batteryRegistryProperties: [String: Any]?
    ) -> PowerTelemetrySnapshot {
        let systemPowerWatts = systemPowerWatts(from: batteryRegistryProperties)
        let chargeRateWatts = chargeRateWatts(from: powerSourceDescription)

        return PowerTelemetrySnapshot(
            batteryLevelText: batteryLevelText(from: powerSourceDescription),
            powerSource: powerSourceText(from: powerSourceDescription),
            systemPowerText: formattedWatts(systemPowerWatts),
            systemPowerWatts: systemPowerWatts,
            chargeRateText: formattedWatts(chargeRateWatts),
            chargeRateWatts: chargeRateWatts,
            powerMetricKind: systemPowerWatts == nil ? nil : .systemPower,
            powerMetricSource: systemPowerWatts == nil ? nil : systemPowerSourceKey
        )
    }

    private static func batteryLevelText(from description: [String: Any]) -> String {
        guard let current = number(from: description[kIOPSCurrentCapacityKey as String]),
              let max = number(from: description[kIOPSMaxCapacityKey as String]),
              max > 0 else {
            return "—"
        }

        let percent = (current / max) * 100
        return String(format: "%.0f%%", percent)
    }

    private static func powerSourceText(from description: [String: Any]) -> String {
        let state = description[kIOPSPowerSourceStateKey as String] as? String
        if state == kIOPSACPowerValue {
            return "AC Power"
        }
        if state == kIOPSBatteryPowerValue {
            return "Battery"
        }
        return state ?? "Unknown"
    }

    private static func systemPowerWatts(from batteryRegistryProperties: [String: Any]?) -> Double? {
        // Prefer the controller's scoped system-power telemetry. The public
        // IOPS voltage/current pair only tells us battery terminal flow.
        guard let batteryRegistryProperties,
              let watts = number(at: ["BatteryData", "SystemPower"], in: batteryRegistryProperties),
              watts > 0.1 else {
            return nil
        }
        return watts
    }

    private static func chargeRateWatts(from description: [String: Any]) -> Double? {
        let isCharging = description[kIOPSIsChargingKey as String] as? Bool ?? false
        guard isCharging,
              let voltageMillivolts = number(from: description[kIOPSVoltageKey as String]),
              let currentMilliamps = number(from: description[kIOPSCurrentKey as String]) else {
            return nil
        }

        let watts = abs(voltageMillivolts * currentMilliamps) / 1_000_000.0
        return watts > 0.1 ? watts : nil
    }

    private static func formattedWatts(_ watts: Double?) -> String {
        guard let watts else {
            return "—"
        }
        return String(format: "%.1f W", watts)
    }

    private static func number(at path: [String], in dictionary: [String: Any]) -> Double? {
        guard let key = path.first else {
            return nil
        }

        if path.count == 1 {
            return number(from: dictionary[key])
        }

        guard let nested = dictionary[key] as? [String: Any] else {
            return nil
        }

        return number(at: Array(path.dropFirst()), in: nested)
    }

    private static func number(from value: Any?) -> Double? {
        switch value {
        case let number as NSNumber:
            return number.doubleValue
        case let value as Double:
            return value
        case let value as Int:
            return Double(value)
        case let value as Float:
            return Double(value)
        default:
            return nil
        }
    }
}

enum PowerTelemetryResolver {
    static func currentSnapshot() -> PowerTelemetrySnapshot {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef],
              !list.isEmpty else {
            return .unavailable
        }

        let batteryRegistryProperties = appleSmartBatteryProperties()

        for powerSource in list {
            guard let description = IOPSGetPowerSourceDescription(snapshot, powerSource)?
                .takeUnretainedValue() as? [String: Any],
                  let type = description[kIOPSTypeKey as String] as? String,
                  type == kIOPSInternalBatteryType as String else {
                continue
            }

            return PowerTelemetryParser.snapshot(
                powerSourceDescription: description,
                batteryRegistryProperties: batteryRegistryProperties
            )
        }

        return .unavailable
    }

    private static func appleSmartBatteryProperties() -> [String: Any]? {
        guard let matching = IOServiceMatching("AppleSmartBattery") else {
            return nil
        }

        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != 0 else {
            return nil
        }
        defer { IOObjectRelease(service) }

        var properties: Unmanaged<CFMutableDictionary>?
        let result = IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0)
        guard result == KERN_SUCCESS,
              let retainedProperties = properties?.takeRetainedValue() as? [String: Any] else {
            return nil
        }

        return retainedProperties
    }
}
