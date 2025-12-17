import Foundation
import Darwin

/// Lightweight snapshot of the system info we want to show in the widget (and can reuse in the app).
struct SystemInfoSnapshot {
    let macOSVersion: String
    let uptime: String
    let freeDiskSpace: String
}

enum SystemInfoProvider {
    /// Take a one-shot reading of the current system info.
    static func snapshot() -> SystemInfoSnapshot {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let versionString = "macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"

        let uptimeString = format(uptimeSeconds: ProcessInfo.processInfo.systemUptime)
        let freeDisk = format(bytes: getFreeDiskSpaceBytes())

        return SystemInfoSnapshot(
            macOSVersion: versionString,
            uptime: uptimeString,
            freeDiskSpace: freeDisk
        )
    }

    // MARK: - Private helpers

    private static func getFreeDiskSpaceBytes() -> Int64 {
        let url = URL(fileURLWithPath: "/")
        if let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let capacity = values.volumeAvailableCapacityForImportantUsage {
            return capacity
        }
        return 0
    }

    private static func format(bytes: Int64) -> String {
        guard bytes > 0 else { return "—" }
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(bytes)
        var index = 0
        while value > 1024 && index < units.count - 1 {
            value /= 1024
            index += 1
        }
        return String(format: "%.1f %@", value, units[index])
    }

    private static func format(uptimeSeconds: TimeInterval) -> String {
        let seconds = Int(uptimeSeconds)
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60

        var components: [String] = []
        if days > 0 { components.append("\(days)d") }
        if hours > 0 || !components.isEmpty { components.append("\(hours)h") }
        components.append("\(minutes)m")
        return components.joined(separator: " ")
    }
}


