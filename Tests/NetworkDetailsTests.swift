import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("Expectation failed: \(message)\n", stderr)
        exit(1)
    }
}

@main
struct NetworkDetailsTests {
    static func main() throws {
        try testDirectSSIDWins()
        try testCachedScanRecordProvidesSSIDFallback()
        testPrimaryInterfaceNameReadsDynamicStoreState()
        print("Network details tests passed")
    }

    private static func testDirectSSIDWins() throws {
        let state: [String: Any] = ["SSID_STR": "OfficeWiFi"]
        expect(
            NetworkDetailsResolver.ssid(fromAirPortState: state) == "OfficeWiFi",
            "explicit SSID_STR should be used directly"
        )
    }

    private static func testCachedScanRecordProvidesSSIDFallback() throws {
        let archived = try NSKeyedArchiver.archivedData(
            withRootObject: ["SSID_STR": "TP-Link_C858"],
            requiringSecureCoding: false
        )

        let state: [String: Any] = [
            "SSID_STR": "",
            "CachedScanRecord": archived
        ]

        expect(
            NetworkDetailsResolver.ssid(fromAirPortState: state) == "TP-Link_C858",
            "cached scan record should surface the network name when the live field is blank"
        )
    }

    private static func testPrimaryInterfaceNameReadsDynamicStoreState() {
        let state: [String: Any] = ["PrimaryInterface": "en0"]
        expect(
            NetworkDetailsResolver.primaryInterfaceName(fromGlobalIPv4State: state) == "en0",
            "primary interface should come from the global IPv4 state"
        )
    }
}
