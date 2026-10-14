import Foundation
import IOKit.ps

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("Expectation failed: \(message)\n", stderr)
        exit(1)
    }
}

@main
struct PowerTelemetryTests {
    static func main() {
        testSystemPowerPrefersScopedTelemetry()
        testChargeRateOnlyShowsWhenCharging()
        testBatteryHealthFallsBackToConditionWhenPresent()
        testBatteryHealthIncludesSystemProfileCapacity()
        testBatteryTemperatureConvertsHundredthsOfDegreesCelsius()
        testBatteryTemperatureRejectsImplausibleValues()
        testBatteryTimeRemainingFormatsDischarging()
        testBatteryTimeRemainingFormatsCharging()
        testBatteryTimeRemainingShowsCalculatingForUnknownEstimate()
        testBatteryTimeRemainingReportsFullyCharged()
        print("Power telemetry tests passed")
    }

    private static func testSystemPowerPrefersScopedTelemetry() {
        let description: [String: Any] = [
            kIOPSCurrentCapacityKey as String: 50.0,
            kIOPSMaxCapacityKey as String: 100.0,
            kIOPSPowerSourceStateKey as String: kIOPSACPowerValue,
            kIOPSIsChargingKey as String: true,
            kIOPSVoltageKey as String: 12_000.0,
            kIOPSCurrentKey as String: 1_500.0
        ]

        let registry: [String: Any] = [
            "BatteryData": [
                "SystemPower": 10_272.5
            ]
        ]

        let snapshot = PowerTelemetryParser.snapshot(
            powerSourceDescription: description,
            batteryRegistryProperties: registry
        )

        expect(snapshot.batteryLevelText == "50%", "battery level should be derived from current and max capacity")
        expect(snapshot.powerSource == "AC Power", "power source should remain AC Power")
        expect(snapshot.systemPowerText == "10.3 W", "system power should prefer scoped telemetry")
        expect(abs((snapshot.systemPowerWatts ?? 0) - 10.2725) < 0.0001, "system power watts should keep the telemetry value")
        expect(snapshot.chargeRateText == "18.0 W", "charge rate should still come from battery flow")
        expect(snapshot.powerMetricKind == .systemPower, "scoped system power samples should be tagged for history")
        expect(
            snapshot.powerMetricSource == "AppleSmartBattery/BatteryData.SystemPower",
            "power metric source should explain the scoped telemetry key"
        )
    }

    private static func testChargeRateOnlyShowsWhenCharging() {
        let description: [String: Any] = [
            kIOPSCurrentCapacityKey as String: 42.0,
            kIOPSMaxCapacityKey as String: 84.0,
            kIOPSPowerSourceStateKey as String: kIOPSBatteryPowerValue,
            kIOPSIsChargingKey as String: false,
            kIOPSBatteryHealthKey as String: kIOPSGoodValue,
            kIOPSVoltageKey as String: 12_000.0,
            kIOPSCurrentKey as String: -900.0
        ]

        let snapshot = PowerTelemetryParser.snapshot(
            powerSourceDescription: description,
            batteryRegistryProperties: nil
        )

        expect(snapshot.batteryLevelText == "50%", "battery level should still be available")
        expect(snapshot.powerSource == "Battery", "power source should describe battery operation")
        expect(snapshot.systemPowerText == "—", "system power should stay unavailable without scoped telemetry")
        expect(snapshot.chargeRateText == "—", "charge rate should not show during discharge")
        expect(snapshot.powerMetricKind == nil, "unscoped samples should not be marked as system power")
        expect(snapshot.batteryHealthText == "Normal", "battery health should come from the public IOPS health key")
    }

    private static func testBatteryHealthFallsBackToConditionWhenPresent() {
        let description: [String: Any] = [
            kIOPSCurrentCapacityKey as String: 60.0,
            kIOPSMaxCapacityKey as String: 100.0,
            kIOPSPowerSourceStateKey as String: kIOPSACPowerValue,
            kIOPSBatteryHealthKey as String: kIOPSGoodValue,
            kIOPSBatteryHealthConditionKey as String: kIOPSCheckBatteryValue
        ]

        let snapshot = PowerTelemetryParser.snapshot(
            powerSourceDescription: description,
            batteryRegistryProperties: nil
        )

        expect(
            snapshot.batteryHealthText == "Check Battery",
            "battery health should prefer a more specific battery condition when one is present"
        )
    }

    private static func testBatteryHealthIncludesSystemProfileCapacity() {
        let description: [String: Any] = [
            kIOPSCurrentCapacityKey as String: 88.0,
            kIOPSMaxCapacityKey as String: 100.0,
            kIOPSPowerSourceStateKey as String: kIOPSBatteryPowerValue,
            kIOPSBatteryHealthKey as String: kIOPSGoodValue
        ]

        let registry: [String: Any] = [
            "CycleCount": 113
        ]

        let snapshot = PowerTelemetryParser.snapshot(
            powerSourceDescription: description,
            batteryRegistryProperties: registry,
            systemProfileHealthInfo: SystemProfileBatteryHealthInfo(
                conditionText: "Normal",
                maximumCapacityText: "98%",
                cycleCountText: "113"
            )
        )

        expect(snapshot.batteryHealthText == "Normal · 98%", "battery health should include condition and maximum capacity")
        expect(snapshot.batteryMaximumCapacityText == "98%", "maximum capacity should be exposed separately")
        expect(snapshot.batteryCycleCountText == "113", "cycle count should be exposed separately")
    }

    private static func testBatteryTemperatureConvertsHundredthsOfDegreesCelsius() {
        // AppleSmartBattery reports Temperature as integer hundredths of °C —
        // 3120 → 31.20 °C.
        let registry: [String: Any] = ["Temperature": 3120]
        let celsius = PowerTelemetryParser.batteryTemperatureCelsius(from: registry)
        expect(celsius != nil, "temperature parser should accept the top-level Temperature key")
        expect(abs((celsius ?? 0) - 31.2) < 0.001, "temperature should be raw value divided by 100")

        let nestedRegistry: [String: Any] = ["BatteryData": ["Temperature": 2895]]
        let nestedCelsius = PowerTelemetryParser.batteryTemperatureCelsius(from: nestedRegistry)
        expect(nestedCelsius != nil, "temperature parser should fall back to BatteryData.Temperature")
        expect(abs((nestedCelsius ?? 0) - 28.95) < 0.001, "nested temperature should also be divided by 100")
    }

    private static func testBatteryTemperatureRejectsImplausibleValues() {
        // Zero is a common uninitialised reading; 200 °C (raw 20000) is out of
        // physical operating range — both should be rejected as noise.
        let zeroRegistry: [String: Any] = ["Temperature": 0]
        expect(
            PowerTelemetryParser.batteryTemperatureCelsius(from: zeroRegistry) == nil,
            "uninitialised zero readings should not be reported"
        )

        let outOfRangeRegistry: [String: Any] = ["Temperature": 20_000]
        expect(
            PowerTelemetryParser.batteryTemperatureCelsius(from: outOfRangeRegistry) == nil,
            "physically impossible readings should not be reported"
        )
    }

    private static func testBatteryTimeRemainingFormatsDischarging() {
        let description: [String: Any] = [
            kIOPSIsChargingKey as String: false,
            kIOPSIsChargedKey as String: false,
            kIOPSTimeToEmptyKey as String: 135
        ]

        let text = PowerTelemetryParser.batteryTimeRemainingText(from: description)
        expect(text == "2h 15m remaining", "discharging time should format as hours/minutes with 'remaining'")
    }

    private static func testBatteryTimeRemainingFormatsCharging() {
        let description: [String: Any] = [
            kIOPSIsChargingKey as String: true,
            kIOPSIsChargedKey as String: false,
            kIOPSTimeToFullChargeKey as String: 45
        ]

        let text = PowerTelemetryParser.batteryTimeRemainingText(from: description)
        expect(text == "45m to full", "charging time under an hour should drop the hour component and end with 'to full'")
    }

    private static func testBatteryTimeRemainingShowsCalculatingForUnknownEstimate() {
        // IOKit returns -1 while the kernel is still gathering enough samples
        // to produce an estimate (typical right after waking from sleep).
        let description: [String: Any] = [
            kIOPSIsChargingKey as String: false,
            kIOPSIsChargedKey as String: false,
            kIOPSTimeToEmptyKey as String: -1
        ]

        let text = PowerTelemetryParser.batteryTimeRemainingText(from: description)
        expect(text == "Calculating…", "negative IOPS estimates should surface as the calculating placeholder")
    }

    private static func testBatteryTimeRemainingReportsFullyCharged() {
        let description: [String: Any] = [
            kIOPSIsChargingKey as String: false,
            kIOPSIsChargedKey as String: true
        ]

        let text = PowerTelemetryParser.batteryTimeRemainingText(from: description)
        expect(text == "Fully charged", "charged batteries should short-circuit before reading the time keys")
    }
}
