import Foundation
import Darwin

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
    // Store previous CPU ticks for delta calculation
    private static var previousCPUTicks: (user: Double, system: Double, idle: Double, nice: Double)?
    
    static func snapshot() -> SystemInfoSnapshot {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let versionString = "macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"

        let uptimeString = format(uptimeSeconds: ProcessInfo.processInfo.systemUptime)
        let freeDisk = getFreeDiskSpaceBytes()
        let totalDisk = getTotalDiskSpaceBytes()
        let memoryUsage = memoryUsageSummary()
        let cpuUsage = cpuUsageSummary()
        
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
            cpuUsage: cpuUsage,
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
        let totalBytes = Double(ProcessInfo.processInfo.physicalMemory)

        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout.size(ofValue: stats) / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, intPtr, &count)
            }
        }

        guard result == KERN_SUCCESS else { return "—" }

        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)

        let freeBytes = Double(stats.free_count) * Double(pageSize)
        let cacheBytes = Double(stats.inactive_count + stats.speculative_count) * Double(pageSize)
        let usedBytes = max(totalBytes - freeBytes - cacheBytes, 0)

        let usedGB = usedBytes / 1024 / 1024 / 1024
        let totalGB = totalBytes / 1024 / 1024 / 1024

        return String(format: "%.1f / %.1f GB", usedGB, totalGB)
    }
    
    private static func cpuUsageSummary() -> String {
        var size = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        var info = host_cpu_load_info()

        let result = withUnsafeMutablePointer(to: &info) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(size)) { intPtr in
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, intPtr, &size)
            }
        }

        guard result == KERN_SUCCESS else { return "—" }

        let user = Double(info.cpu_ticks.0)
        let system = Double(info.cpu_ticks.1)
        let idle = Double(info.cpu_ticks.2)
        let nice = Double(info.cpu_ticks.3)

        let current = (user: user, system: system, idle: idle, nice: nice)

        guard let previous = previousCPUTicks else {
            previousCPUTicks = current
            return "—"
        }

        let userDiff = current.user - previous.user
        let systemDiff = current.system - previous.system
        let idleDiff = current.idle - previous.idle
        let niceDiff = current.nice - previous.nice

        let totalTicks = userDiff + systemDiff + idleDiff + niceDiff
        guard totalTicks > 0 else { return "—" }

        let busyTicks = userDiff + systemDiff + niceDiff
        let percent = (busyTicks / totalTicks) * 100

        previousCPUTicks = current
        return String(format: "%.0f%%", percent)
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
