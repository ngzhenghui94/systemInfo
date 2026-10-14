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
        testRouterReadsFromGlobalIPv4State()
        testRouterReturnsNilWhenMissingOrBlank()
        testDNSServersJoinsAddressesWithCommas()
        testDNSServersReturnsNilForEmptyOrMalformedState()
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

    private static func testRouterReadsFromGlobalIPv4State() {
        let state: [String: Any] = ["Router": "192.168.1.1"]
        expect(
            NetworkDetailsResolver.router(fromGlobalIPv4State: state) == "192.168.1.1",
            "router should be pulled directly from the Router key"
        )
    }

    private static func testRouterReturnsNilWhenMissingOrBlank() {
        expect(
            NetworkDetailsResolver.router(fromGlobalIPv4State: [:]) == nil,
            "missing Router key should return nil so the UI shows '—'"
        )
        expect(
            NetworkDetailsResolver.router(fromGlobalIPv4State: ["Router": "  "]) == nil,
            "whitespace-only Router values should also be treated as absent"
        )
    }

    private static func testDNSServersJoinsAddressesWithCommas() {
        let state: [String: Any] = ["ServerAddresses": ["8.8.8.8", "1.1.1.1"]]
        expect(
            NetworkDetailsResolver.dnsServers(fromState: state) == "8.8.8.8, 1.1.1.1",
            "multiple DNS servers should be joined with a comma+space separator"
        )
    }

    private static func testDNSServersReturnsNilForEmptyOrMalformedState() {
        expect(
            NetworkDetailsResolver.dnsServers(fromState: [:]) == nil,
            "missing ServerAddresses key should return nil"
        )
        expect(
            NetworkDetailsResolver.dnsServers(fromState: ["ServerAddresses": [String]()]) == nil,
            "empty ServerAddresses array should return nil"
        )
        expect(
            NetworkDetailsResolver.dnsServers(fromState: ["ServerAddresses": ["", "  "]]) == nil,
            "ServerAddresses entries that are all blank should return nil"
        )
    }
}
