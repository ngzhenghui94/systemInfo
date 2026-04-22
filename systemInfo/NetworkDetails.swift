import Foundation
import SystemConfiguration

enum NetworkDetailsResolver {
    static func currentWiFiSSID() -> String {
        guard let store = SCDynamicStoreCreate(nil, "systemInfo" as CFString, nil, nil) else {
            return "—"
        }

        let primaryInterface = currentPrimaryInterfaceName(store: store)
        let candidateInterfaces = airPortInterfaces(store: store, preferredInterface: primaryInterface)

        for interface in candidateInterfaces {
            guard let state = airPortState(for: interface, store: store),
                  let ssid = ssid(fromAirPortState: state) else {
                continue
            }
            return ssid
        }

        return "—"
    }

    static func currentIPv4Address() -> String {
        let preferredInterface = currentPrimaryInterfaceName()
        var candidates = [String]()
        if let preferredInterface, !preferredInterface.isEmpty {
            candidates.append(preferredInterface)
        }
        candidates.append(contentsOf: ["en0", "en1"])

        var seen = Set<String>()
        let uniqueCandidates = candidates.filter { seen.insert($0).inserted }
        return ipv4Address(on: uniqueCandidates) ?? "—"
    }

    static func primaryInterfaceName(fromGlobalIPv4State state: [String: Any]) -> String? {
        guard let interface = state["PrimaryInterface"] as? String else {
            return nil
        }

        let trimmed = interface.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func ssid(fromAirPortState state: [String: Any]) -> String? {
        if let directSSID = sanitizedSSID(from: state["SSID_STR"]) {
            return directSSID
        }

        if let directSSIDData = state["SSID"] as? Data,
           let decodedSSID = sanitizedSSID(fromData: directSSIDData) {
            return decodedSSID
        }

        guard let cachedScanRecord = state["CachedScanRecord"] as? Data,
              let cachedState = unarchiveDictionary(from: cachedScanRecord) else {
            return nil
        }

        if let cachedSSID = sanitizedSSID(from: cachedState["SSID_STR"]) {
            return cachedSSID
        }

        if let cachedSSIDData = cachedState["SSID"] as? Data {
            return sanitizedSSID(fromData: cachedSSIDData)
        }

        return nil
    }

    private static func currentPrimaryInterfaceName(store: SCDynamicStore? = nil) -> String? {
        let resolvedStore = store ?? SCDynamicStoreCreate(nil, "systemInfo" as CFString, nil, nil)
        guard let resolvedStore,
              let globalState = SCDynamicStoreCopyValue(resolvedStore, "State:/Network/Global/IPv4" as NSString) as? [String: Any] else {
            return nil
        }

        return primaryInterfaceName(fromGlobalIPv4State: globalState)
    }

    private static func airPortInterfaces(store: SCDynamicStore, preferredInterface: String?) -> [String] {
        let keys = (SCDynamicStoreCopyKeyList(store, "State:/Network/Interface/.*/AirPort" as CFString) as? [String]) ?? []
        let names = keys.compactMap { key -> String? in
            let components = key.split(separator: "/")
            guard components.count >= 4 else { return nil }
            return String(components[3])
        }

        var ordered = [String]()
        if let preferredInterface, names.contains(preferredInterface) {
            ordered.append(preferredInterface)
        }
        ordered.append(contentsOf: names.filter { $0 != preferredInterface })
        return ordered
    }

    private static func airPortState(for interface: String, store: SCDynamicStore) -> [String: Any]? {
        let key = "State:/Network/Interface/\(interface)/AirPort" as NSString
        return SCDynamicStoreCopyValue(store, key) as? [String: Any]
    }

    private static func ipv4Address(on interfaces: [String]) -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else {
            return nil
        }
        defer { freeifaddrs(ifaddr) }

        var ptr = firstAddr
        while true {
            let interface = ptr.pointee
            let name = String(cString: interface.ifa_name)
            let family = interface.ifa_addr.pointee.sa_family

            if family == UInt8(AF_INET), interfaces.contains(name) {
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                getnameinfo(
                    interface.ifa_addr,
                    socklen_t(interface.ifa_addr.pointee.sa_len),
                    &hostname,
                    socklen_t(hostname.count),
                    nil,
                    0,
                    NI_NUMERICHOST
                )

                let address = String(cString: hostname)
                if address != "127.0.0.1" {
                    return address
                }
            }

            guard let next = interface.ifa_next else { break }
            ptr = next
        }

        return nil
    }

    private static func unarchiveDictionary(from data: Data) -> [String: Any]? {
        let allowedClasses: [AnyClass] = [
            NSDictionary.self,
            NSArray.self,
            NSString.self,
            NSData.self,
            NSNumber.self,
            NSDate.self
        ]

        guard let object = try? NSKeyedUnarchiver.unarchivedObject(ofClasses: allowedClasses, from: data) else {
            return nil
        }

        if let dictionary = object as? [String: Any] {
            return dictionary
        }

        if let dictionary = object as? NSDictionary {
            return dictionary as? [String: Any]
        }

        return nil
    }

    private static func sanitizedSSID(from value: Any?) -> String? {
        guard let string = value as? String else {
            return nil
        }

        let trimmed = string
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: .controlCharacters)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func sanitizedSSID(fromData data: Data) -> String? {
        guard let string = String(data: data, encoding: .utf8) else {
            return nil
        }

        let trimmed = string
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: .controlCharacters)
        return trimmed.isEmpty ? nil : trimmed
    }
}
