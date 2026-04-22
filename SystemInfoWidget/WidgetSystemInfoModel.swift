import Foundation

/// Lightweight snapshot of the system info for the widget target.
struct SystemInfoSnapshot {
    let macOSVersion: String
    let memoryUsage: String
    let uptime: String
    let freeDiskSpace: String
    let cpuUsage: String
    let totalDiskSpace: String
    let diskUsagePercent: Double
}

enum SystemInfoProvider {
    static func snapshot() -> SystemInfoSnapshot {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let versionString = "macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"

        let uptimeString = format(uptimeSeconds: ProcessInfo.processInfo.systemUptime)
        let freeDisk = getFreeDiskSpaceBytes()
        let totalDisk = getTotalDiskSpaceBytes()
        let memoryUsage = memoryUsageSummary()
        
        let diskUsagePercent: Double
        if totalDisk > 0 {
            diskUsagePercent = Double(totalDisk - freeDisk) / Double(totalDisk)
        } else {
            diskUsagePercent = 0
        }

        return SystemInfoSnapshot(
            macOSVersion: versionString,
            memoryUsage: memoryUsage,
            uptime: uptimeString,
            freeDiskSpace: format(bytes: freeDisk),
            cpuUsage: "—", // CPU stats not available in widget extension
            totalDiskSpace: format(bytes: totalDisk),
            diskUsagePercent: diskUsagePercent
        )
    }

    private static func getFreeDiskSpaceBytes() -> Int64 {
        let url = URL(fileURLWithPath: "/")
        if let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let capacity = values.volumeAvailableCapacityForImportantUsage {
            return capacity
        }
        return 0
    }
    
    private static func getTotalDiskSpaceBytes() -> Int64 {
        let url = URL(fileURLWithPath: "/")
        if let values = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey]),
           let capacity = values.volumeTotalCapacity {
            return Int64(capacity)
        }
        return 0
    }

    private static func memoryUsageSummary() -> String {
        // Use ProcessInfo for total memory (simple API that works in widgets)
        let totalBytes = Double(ProcessInfo.processInfo.physicalMemory)
        let totalGB = totalBytes / 1024 / 1024 / 1024
        
        // For widgets, we can only show total memory reliably
        // Detailed memory stats require Mach calls which have linker issues
        return String(format: "%.0f GB", totalGB)
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
