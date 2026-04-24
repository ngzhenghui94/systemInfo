import Foundation
import IOKit
import IOKit.ps

enum PowerMetricKind: String, Codable {
    case systemPower
}

struct PowerTelemetrySnapshot: Equatable {
    let batteryLevelText: String
    let batteryHealthText: String
    let batteryMaximumCapacityText: String
    let batteryCycleCountText: String
    let powerSource: String
    let systemPowerText: String
    let systemPowerWatts: Double?
    let chargeRateText: String
    let chargeRateWatts: Double?
    let powerMetricKind: PowerMetricKind?
    let powerMetricSource: String?

    static let unavailable = PowerTelemetrySnapshot(
        batteryLevelText: "—",
        batteryHealthText: "—",
        batteryMaximumCapacityText: "—",
        batteryCycleCountText: "—",
        powerSource: "No battery",
        systemPowerText: "—",
        systemPowerWatts: nil,
        chargeRateText: "—",
        chargeRateWatts: nil,
        powerMetricKind: nil,
        powerMetricSource: nil
    )
}

struct SystemProfileBatteryHealthInfo: Equatable {
    let conditionText: String?
    let maximumCapacityText: String?
    let cycleCountText: String?
}

private struct BatteryHealthDetails {
    let conditionText: String
    let maximumCapacityText: String
    let cycleCountText: String

    var summaryText: String {
        let parts = [conditionText, maximumCapacityText].filter { $0 != "—" }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }
}

enum PowerTelemetryParser {
    static let systemPowerSourceKey    = "AppleSmartBattery/BatteryData.SystemPower"
    static let systemLoadSourceKey     = "AppleSmartBattery/PowerTelemetryData.SystemLoad"

    static func snapshot(
        powerSourceDescription: [String: Any],
        batteryRegistryProperties: [String: Any]?,
        systemProfileHealthInfo: SystemProfileBatteryHealthInfo? = nil
    ) -> PowerTelemetrySnapshot {
        let powerResult    = systemPowerResult(from: batteryRegistryProperties)
        let chargeRateWatts = chargeRateWatts(from: powerSourceDescription)
        let batteryHealth = batteryHealthDetails(
            from: powerSourceDescription,
            batteryRegistryProperties: batteryRegistryProperties,
            systemProfileHealthInfo: systemProfileHealthInfo
        )

        return PowerTelemetrySnapshot(
            batteryLevelText: batteryLevelText(from: powerSourceDescription),
            batteryHealthText: batteryHealth.summaryText,
            batteryMaximumCapacityText: batteryHealth.maximumCapacityText,
            batteryCycleCountText: batteryHealth.cycleCountText,
            powerSource: powerSourceText(from: powerSourceDescription),
            systemPowerText: formattedWatts(powerResult?.watts),
            systemPowerWatts: powerResult?.watts,
            chargeRateText: formattedWatts(chargeRateWatts),
            chargeRateWatts: chargeRateWatts,
            powerMetricKind: powerResult == nil ? nil : .systemPower,
            powerMetricSource: powerResult?.source
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

    private static func batteryHealthDetails(
        from description: [String: Any],
        batteryRegistryProperties: [String: Any]?,
        systemProfileHealthInfo: SystemProfileBatteryHealthInfo?
    ) -> BatteryHealthDetails {
        let condition = systemProfileHealthInfo?.conditionText
            ?? batteryConditionText(from: description)
            ?? "—"

        let maximumCapacity = systemProfileHealthInfo?.maximumCapacityText
            ?? maximumCapacityText(from: batteryRegistryProperties)
            ?? "—"

        let cycleCount = systemProfileHealthInfo?.cycleCountText
            ?? integerText(at: ["CycleCount"], in: batteryRegistryProperties)
            ?? integerText(at: ["BatteryData", "CycleCount"], in: batteryRegistryProperties)
            ?? "—"

        return BatteryHealthDetails(
            conditionText: condition,
            maximumCapacityText: maximumCapacity,
            cycleCountText: cycleCount
        )
    }

    private static func batteryConditionText(from description: [String: Any]) -> String? {
        if let condition = string(from: description[kIOPSBatteryHealthConditionKey as String]) {
            return normalizedBatteryCondition(condition)
        }

        if let health = string(from: description[kIOPSBatteryHealthKey as String]) {
            return normalizedBatteryCondition(health)
        }

        return nil
    }

    private static func normalizedBatteryCondition(_ text: String) -> String {
        text == kIOPSGoodValue ? "Normal" : text
    }

    private static func maximumCapacityText(from properties: [String: Any]?) -> String? {
        guard let properties else { return nil }

        let directPercentPaths = [
            ["BatteryData", "BatteryHealthMaximumCapacity"],
            ["BatteryData", "MaximumCapacityPercent"],
            ["BatteryHealthMaximumCapacity"],
            ["MaximumCapacityPercent"]
        ]

        for path in directPercentPaths {
            if let text = percentText(at: path, in: properties) {
                return text
            }
        }

        let capacityPairs = [
            (["NominalChargeCapacity"], ["DesignCapacity"]),
            (["AppleRawMaxCapacity"], ["DesignCapacity"]),
            (["BatteryData", "FccComp1"], ["BatteryData", "DesignCapacity"])
        ]

        for (currentPath, designPath) in capacityPairs {
            guard let current = number(at: currentPath, in: properties),
                  let design = number(at: designPath, in: properties),
                  current > 0,
                  design > 0 else {
                continue
            }

            let percent = (current / design) * 100
            guard percent >= 1, percent <= 150 else {
                continue
            }
            return String(format: "%.0f%%", percent)
        }

        return nil
    }

    /// Returns the system power consumption in watts plus the IOKit key path that
    /// provided the reading, or nil when no valid sample is available.
    ///
    /// All power fields in AppleSmartBattery are reported in **milliwatts**;
    /// this function divides by 1 000 before returning.
    ///
    /// Sources tried in order:
    ///  1. `BatteryData.SystemPower`         – scoped controller telemetry, active during
    ///                                         battery discharge; often empty on AC.
    ///  2. `PowerTelemetryData.SystemLoad`   – total system consumption, available on
    ///                                         both battery and AC.
    private static func systemPowerResult(
        from batteryRegistryProperties: [String: Any]?
    ) -> (watts: Double, source: String)? {
        guard let props = batteryRegistryProperties else { return nil }

        let candidates: [([String], String)] = [
            (["BatteryData", "SystemPower"],       systemPowerSourceKey),
            (["PowerTelemetryData", "SystemLoad"], systemLoadSourceKey),
        ]

        for (keyPath, source) in candidates {
            // Ignore values ≤ 100 mW — they are noise or uninitialized zeroes.
            if let mw = number(at: keyPath, in: props), mw > 100 {
                return (mw / 1000.0, source)
            }
        }
        return nil
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

    private static func integerText(at path: [String], in dictionary: [String: Any]?) -> String? {
        guard let dictionary,
              let value = number(at: path, in: dictionary) else {
            return nil
        }

        return String(format: "%.0f", value)
    }

    private static func percentText(at path: [String], in dictionary: [String: Any]) -> String? {
        if let text = string(at: path, in: dictionary) {
            return text.hasSuffix("%") ? text : "\(text)%"
        }

        guard let value = number(at: path, in: dictionary),
              value >= 0,
              value <= 150 else {
            return nil
        }

        return String(format: "%.0f%%", value)
    }

    private static func string(at path: [String], in dictionary: [String: Any]) -> String? {
        guard let key = path.first else {
            return nil
        }

        if path.count == 1 {
            return string(from: dictionary[key])
        }

        guard let nested = dictionary[key] as? [String: Any] else {
            return nil
        }

        return string(at: Array(path.dropFirst()), in: nested)
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

    private static func string(from value: Any?) -> String? {
        switch value {
        case let value as String:
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case let value as NSString:
            let trimmed = String(value).trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        default:
            return nil
        }
    }
}

enum PowerTelemetryResolver {
    private static let systemProfileHealthCacheLifetime: TimeInterval = 300
    private static var systemProfileHealthCache: (capturedAt: Date, info: SystemProfileBatteryHealthInfo?)?

    static func currentSnapshot() -> PowerTelemetrySnapshot {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef],
              !list.isEmpty else {
            return .unavailable
        }

        let batteryRegistryProperties = appleSmartBatteryProperties()
        let systemProfileHealthInfo = cachedSystemProfileBatteryHealthInfo()

        for powerSource in list {
            guard let description = IOPSGetPowerSourceDescription(snapshot, powerSource)?
                .takeUnretainedValue() as? [String: Any],
                  let type = description[kIOPSTypeKey as String] as? String,
                  type == kIOPSInternalBatteryType as String else {
                continue
            }

            return PowerTelemetryParser.snapshot(
                powerSourceDescription: description,
                batteryRegistryProperties: batteryRegistryProperties,
                systemProfileHealthInfo: systemProfileHealthInfo
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

    private static func cachedSystemProfileBatteryHealthInfo() -> SystemProfileBatteryHealthInfo? {
        let now = Date()
        if let cache = systemProfileHealthCache,
           now.timeIntervalSince(cache.capturedAt) < systemProfileHealthCacheLifetime {
            return cache.info
        }

        let info = systemProfileBatteryHealthInfo()
        systemProfileHealthCache = (capturedAt: now, info: info)
        return info
    }

    private static func systemProfileBatteryHealthInfo() -> SystemProfileBatteryHealthInfo? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["-xml", "SPPowerDataType"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return nil
        }

        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let root = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [[String: Any]],
              let items = root.first?["_items"] as? [[String: Any]],
              let batteryItem = items.first(where: { ($0["_name"] as? String) == "spbattery_information" }),
              let healthInfo = batteryItem["sppower_battery_health_info"] as? [String: Any] else {
            return nil
        }

        return SystemProfileBatteryHealthInfo(
            conditionText: normalizedSystemProfileCondition(string(from: healthInfo["sppower_battery_health"])),
            maximumCapacityText: percentText(from: healthInfo["sppower_battery_health_maximum_capacity"]),
            cycleCountText: integerText(from: healthInfo["sppower_battery_cycle_count"])
        )
    }

    private static func normalizedSystemProfileCondition(_ text: String?) -> String? {
        guard let text else { return nil }
        return text == kIOPSGoodValue ? "Normal" : text
    }

    private static func percentText(from value: Any?) -> String? {
        if let text = string(from: value) {
            return text.hasSuffix("%") ? text : "\(text)%"
        }

        if let number = number(from: value), number >= 0, number <= 150 {
            return String(format: "%.0f%%", number)
        }

        return nil
    }

    private static func integerText(from value: Any?) -> String? {
        guard let number = number(from: value) else {
            return nil
        }
        return String(format: "%.0f", number)
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

    private static func string(from value: Any?) -> String? {
        switch value {
        case let value as String:
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case let value as NSString:
            let trimmed = String(value).trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        default:
            return nil
        }
    }
}
