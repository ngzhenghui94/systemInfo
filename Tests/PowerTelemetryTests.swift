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
                "SystemPower": 10.2725
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
        expect(snapshot.batteryHealthText == "Good", "battery health should come from the public IOPS health key")
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
}
