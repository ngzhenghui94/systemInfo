//
//  ContentView.swift
//  systemInfo
//
//  Created by Daniel Ng Zheng Hui on 12/9/25.
//

import SwiftUI
import Combine
import Darwin
import AppKit
import IOKit.ps

/// View model that gathers and formats system information for display.
final class SystemInfoViewModel: ObservableObject {
    @Published var macOSVersion: String = ""
    @Published var hostName: String = ""
    @Published var cpuUsage: String = ""
    @Published var loadAverage: String = ""
    @Published var memoryUsage: String = ""
    @Published var batteryLevel: String = ""
    @Published var powerSource: String = ""
    @Published var powerUsage: String = "—"
    @Published var chargingWattage: String = ""
    @Published var uptime: String = ""
    @Published var freeDiskSpace: String = ""
    @Published var downloadSpeed: String = "—"
    @Published var uploadSpeed: String = "—"
    
    // New stats
    @Published var cpuModel: String = ""
    @Published var cpuCores: String = ""
    @Published var gpuName: String = ""
    @Published var thermalState: String = ""
    @Published var totalDiskSpace: String = ""
    @Published var diskUsagePercent: Double = 0
    @Published var ipAddress: String = ""
    @Published var wifiNetwork: String = ""
    @Published var batteryHealth: String = ""
    @Published var batteryTemperature: String = ""
    @Published var batteryCycleCount: String = ""
    @Published var freeMemory: String = ""
    @Published var historySampleCount: Int = 0
    @Published var historyCoverage: String = "0m"
    @Published var lastHistorySave: String = "—"
    @Published var lastReportGenerated: String = "—"
    @Published var latestReportText: String = "Historical samples will appear here once the app captures them."

    private let networkMonitor = NetworkMonitor()
    private let historyStore = SystemHistoryStore()
    private var timer: Timer?
    private var lastPersistedAt: Date?
    private var latestDownloadBytesPerSecond: Double = 0
    private var latestUploadBytesPerSecond: Double = 0

    private let historySaveInterval: TimeInterval = 60

    init() {
        updateStaticInfo()
        hydrateHistory()
        updateDynamicInfo(forcePersist: true)
        startUpdating()
    }

    deinit {
        timer?.invalidate()
    }

    /// Info that rarely changes while the app is running.
    private func updateStaticInfo() {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        macOSVersion = "macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"

        hostName = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        freeDiskSpace = Self.format(bytes: getFreeDiskSpaceBytes())
        memoryUsage = Self.memoryUsageSummary()
        updatePowerInfo()
        
        // New static info
        cpuModel = Self.getCPUModel()
        cpuCores = Self.getCPUCores()
        gpuName = Self.getGPUName()
        totalDiskSpace = Self.format(bytes: getTotalDiskSpaceBytes())
        updateDiskUsage()
    }

    /// Info that should refresh regularly (uptime, network speeds).
    private func startUpdating() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.updateDynamicInfo()
        }
        if let timer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    private func updateDynamicInfo(forcePersist: Bool = false) {
        let now = Date()
        uptime = Self.format(uptimeSeconds: ProcessInfo.processInfo.systemUptime)

        memoryUsage = Self.memoryUsageSummary()
        cpuUsage = Self.cpuUsageSummary()
        loadAverage = Self.loadAverageSummary()

        updatePowerInfo()

        let speeds = networkMonitor.currentSpeeds()
        latestDownloadBytesPerSecond = speeds.download
        latestUploadBytesPerSecond = speeds.upload
        downloadSpeed = Self.format(bytesPerSecond: speeds.download)
        uploadSpeed = Self.format(bytesPerSecond: speeds.upload)
        
        // New dynamic info
        thermalState = Self.getThermalState()
        ipAddress = Self.getIPAddress()
        wifiNetwork = Self.getWiFiSSID()
        freeMemory = Self.getFreeMemory()
        updateDiskUsage()
        persistHistoryIfNeeded(capturedAt: now, force: forcePersist)
    }
    
    private func updateDiskUsage() {
        let total = getTotalDiskSpaceBytes()
        let free = getFreeDiskSpaceBytes()
        if total > 0 {
            diskUsagePercent = Double(total - free) / Double(total)
        }
        freeDiskSpace = Self.format(bytes: free)
    }

    private func getFreeDiskSpaceBytes() -> Int64 {
        let url = URL(fileURLWithPath: "/")
        if let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let capacity = values.volumeAvailableCapacityForImportantUsage {
            return capacity
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
        // Treat inactive + speculative pages as cache (similar to Activity Monitor's "Cached Files")
        let cacheBytes = Double(stats.inactive_count + stats.speculative_count) * Double(pageSize)
        let usedBytes = max(totalBytes - freeBytes - cacheBytes, 0)

        let usedGB = usedBytes / 1024 / 1024 / 1024
        let totalGB = totalBytes / 1024 / 1024 / 1024

        // Show "used / total GB"
        return String(format: "%.1f / %.1f GB", usedGB, totalGB)
    }

    private func updatePowerInfo() {
        let info = Self.batteryInfo()
        batteryLevel = info.level
        powerSource = info.source
        powerUsage = info.usage
        chargingWattage = info.chargeRate
    }

    // Track last CPU ticks so we can compute a delta-based usage percentage.
    private static var previousCPUTicks: (user: Double, system: Double, idle: Double, nice: Double)?

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

    private static func loadAverageSummary() -> String {
        var loads = [Double](repeating: 0, count: 3)
        let count = getloadavg(&loads, 3)
        guard count >= 2 else { return "—" }
        // Show 1‑ and 5‑minute averages.
        return String(format: "%.2f, %.2f", loads[0], loads[1])
    }

    private static func batteryInfo() -> (level: String, source: String, usage: String, chargeRate: String) {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef],
              !list.isEmpty else {
            return ("—", "No battery", "—", "—")
        }

        for ps in list {
            guard let description = IOPSGetPowerSourceDescription(snapshot, ps)?
                .takeUnretainedValue() as? [String: Any],
                  let type = description[kIOPSTypeKey as String] as? String,
                  type == kIOPSInternalBatteryType as String
            else { continue }

            // Battery percentage
            var levelString = "—"
            if let current = description[kIOPSCurrentCapacityKey as String] as? Double,
               let max = description[kIOPSMaxCapacityKey as String] as? Double,
               max > 0 {
                let pct = (current / max) * 100
                levelString = String(format: "%.0f%%", pct)
            }

            // Power source (AC vs Battery)
            let state = description[kIOPSPowerSourceStateKey as String] as? String
            let sourceString: String
            if state == kIOPSACPowerValue {
                sourceString = "AC Power"
            } else if state == kIOPSBatteryPowerValue {
                sourceString = "Battery"
            } else {
                sourceString = state ?? "Unknown"
            }

            // Estimate current battery power flow from the reported voltage/current pair.
            var usageString = "—"
            var chargeRateString = "—"
            if let voltage = description[kIOPSVoltageKey as String] as? Double,
               let currentMA = description[kIOPSCurrentKey as String] as? Double {
                // Voltage is in mV and current is in mA, so dividing by 1_000_000
                // yields watts. We expose it as the live power usage signal and,
                // when charging, also as the charge rate.
                let watts = abs(voltage * currentMA) / 1_000_000.0
                if watts > 0.1 {
                    usageString = String(format: "%.1f W", watts)
                    let isCharging = description[kIOPSIsChargingKey as String] as? Bool ?? false
                    if isCharging {
                        chargeRateString = usageString
                    }
                }
            }

            return (levelString, sourceString, usageString, chargeRateString)
        }

        return ("—", "No battery", "—", "—")
    }

    // MARK: - Formatting helpers

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

    private static func format(bytesPerSecond: Double) -> String {
        guard bytesPerSecond > 0 else { return "0 B/s" }
        let units = ["B/s", "KB/s", "MB/s", "GB/s"]
        var value = bytesPerSecond
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
    
    // MARK: - New Stat Methods
    
    private func getTotalDiskSpaceBytes() -> Int64 {
        let url = URL(fileURLWithPath: "/")
        if let values = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey]),
           let capacity = values.volumeTotalCapacity {
            return Int64(capacity)
        }
        return 0
    }
    
    private static func getCPUModel() -> String {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var buffer = [CChar](repeating: 0, count: size)
        sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0)
        let model = String(cString: buffer)
        // Shorten common prefixes
        return model
            .replacingOccurrences(of: "Intel(R) Core(TM) ", with: "")
            .replacingOccurrences(of: "Apple ", with: "")
            .trimmingCharacters(in: .whitespaces)
    }
    
    private static func getCPUCores() -> String {
        let physical = ProcessInfo.processInfo.processorCount
        var logical = 0
        var size = MemoryLayout<Int>.size
        sysctlbyname("hw.logicalcpu", &logical, &size, nil, 0)
        if logical > 0 && logical != physical {
            return "\(physical)P / \(logical)L"
        }
        return "\(physical) cores"
    }
    
    private static func getGPUName() -> String {
        // Use IOKit to get GPU info
        let matchDict = IOServiceMatching("IOPCIDevice")
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matchDict, &iterator) == KERN_SUCCESS else {
            return "—"
        }
        defer { IOObjectRelease(iterator) }
        
        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer { 
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }
            
            if let modelData = IORegistryEntryCreateCFProperty(service, "model" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Data {
                if let model = String(data: modelData, encoding: .utf8)?.trimmingCharacters(in: .controlCharacters) {
                    if model.contains("GPU") || model.contains("Graphics") || model.contains("M1") || model.contains("M2") || model.contains("M3") || model.contains("M4") {
                        return model
                    }
                }
            }
        }
        
        // Fallback for Apple Silicon
        #if arch(arm64)
        return "Apple GPU"
        #else
        return "—"
        #endif
    }
    
    private static func getThermalState() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal:
            return "Normal"
        case .fair:
            return "Fair"
        case .serious:
            return "Serious"
        case .critical:
            return "Critical"
        @unknown default:
            return "Unknown"
        }
    }
    
    private static func getIPAddress() -> String {
        var address = "—"
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else {
            return address
        }
        defer { freeifaddrs(ifaddr) }
        
        var ptr = firstAddr
        while true {
            let interface = ptr.pointee
            let addrFamily = interface.ifa_addr.pointee.sa_family
            
            if addrFamily == UInt8(AF_INET) { // IPv4
                let name = String(cString: interface.ifa_name)
                if name == "en0" || name == "en1" { // Wi-Fi or Ethernet
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                               &hostname, socklen_t(hostname.count),
                               nil, 0, NI_NUMERICHOST)
                    address = String(cString: hostname)
                    break
                }
            }
            
            guard let next = interface.ifa_next else { break }
            ptr = next
        }
        
        return address
    }
    
    private static func getWiFiSSID() -> String {
        // On macOS, we can use CoreWLAN but it requires the CoreWLAN framework
        // For now, return a placeholder or use a simpler approach
        let task = Process()
        task.launchPath = "/System/Library/PrivateFrameworks/Apple80211.framework/Versions/Current/Resources/airport"
        task.arguments = ["-I"]
        
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        
        do {
            try task.run()
            task.waitUntilExit()
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                for line in output.components(separatedBy: "\n") {
                    if line.contains("SSID:") && !line.contains("BSSID") {
                        let parts = line.components(separatedBy: ":")
                        if parts.count >= 2 {
                            return parts[1].trimmingCharacters(in: .whitespaces)
                        }
                    }
                }
            }
        } catch {
            return "—"
        }
        
        return "Not connected"
    }
    
    private static func getFreeMemory() -> String {
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
        
        let totalBytes = Double(ProcessInfo.processInfo.physicalMemory)
        let freeBytes = Double(stats.free_count) * Double(pageSize)
        let cacheBytes = Double(stats.inactive_count + stats.speculative_count) * Double(pageSize)
        let availableBytes = freeBytes + cacheBytes
        
        let availableGB = availableBytes / 1024 / 1024 / 1024
        let totalGB = totalBytes / 1024 / 1024 / 1024
        
        return String(format: "%.1f / %.1f GB", availableGB, totalGB)
    }

    private func hydrateHistory() {
        do {
            let samples = try historyStore.loadSamples()
            updateHistoryMetadata(with: samples)

            if let report = try historyStore.loadReport() {
                latestReportText = report
                lastReportGenerated = Self.format(timestamp: samples.last?.capturedAt)
            } else if !samples.isEmpty {
                let report = try historyStore.refreshReport(using: samples, generatedAt: Date())
                latestReportText = report
                lastReportGenerated = Self.format(timestamp: Date())
            }
        } catch {
            latestReportText = "Unable to load monitoring history: \(error.localizedDescription)"
        }
    }

    private func persistHistoryIfNeeded(capturedAt: Date, force: Bool = false) {
        if !force, let lastPersistedAt, capturedAt.timeIntervalSince(lastPersistedAt) < historySaveInterval {
            return
        }

        do {
            let samples = try historyStore.record(currentHistorySample(capturedAt: capturedAt))
            let report = try historyStore.refreshReport(using: samples, generatedAt: capturedAt)

            lastPersistedAt = capturedAt
            lastHistorySave = Self.format(timestamp: capturedAt)
            lastReportGenerated = Self.format(timestamp: capturedAt)
            latestReportText = report
            updateHistoryMetadata(with: samples)
        } catch {
            latestReportText = "Unable to persist monitoring history: \(error.localizedDescription)"
        }
    }

    private func updateHistoryMetadata(with samples: [SystemHistorySample]) {
        let overview = historyStore.overview(for: samples)
        historySampleCount = overview.sampleCount
        historyCoverage = overview.coverageText

        if let lastCapturedAt = samples.last?.capturedAt, lastHistorySave == "—" {
            lastHistorySave = Self.format(timestamp: lastCapturedAt)
        }
    }

    private func currentHistorySample(capturedAt: Date) -> SystemHistorySample {
        let memoryParts = Self.parseUsedTotalPair(from: memoryUsage)
        let loadAverageParts = Self.parseLoadAverage(from: loadAverage)

        return SystemHistorySample(
            capturedAt: capturedAt,
            hostName: hostName,
            macOSVersion: macOSVersion,
            cpuModel: cpuModel,
            cpuCores: cpuCores,
            gpuName: gpuName,
            cpuUsageText: cpuUsage,
            cpuUsagePercent: Self.parsePercent(from: cpuUsage),
            loadAverageText: loadAverage,
            loadAverageOneMinute: loadAverageParts.oneMinute,
            loadAverageFiveMinute: loadAverageParts.fiveMinute,
            memoryUsageText: memoryUsage,
            memoryUsedGB: memoryParts.used,
            memoryTotalGB: memoryParts.total,
            batteryLevelText: batteryLevel,
            batteryLevelPercent: Self.parsePercent(from: batteryLevel),
            powerSource: powerSource,
            powerUsageText: powerUsage,
            powerUsageWatts: Self.parseWatts(from: powerUsage),
            chargingWattageText: chargingWattage,
            uptimeText: uptime,
            uptimeSeconds: ProcessInfo.processInfo.systemUptime,
            freeDiskSpaceText: freeDiskSpace,
            freeDiskBytes: getFreeDiskSpaceBytes(),
            totalDiskSpaceText: totalDiskSpace,
            totalDiskBytes: getTotalDiskSpaceBytes(),
            diskUsagePercent: diskUsagePercent,
            downloadSpeedText: downloadSpeed,
            downloadBytesPerSecond: latestDownloadBytesPerSecond,
            uploadSpeedText: uploadSpeed,
            uploadBytesPerSecond: latestUploadBytesPerSecond,
            thermalState: thermalState,
            ipAddress: ipAddress,
            wifiNetwork: wifiNetwork,
            freeMemoryText: freeMemory
        )
    }

    func openLatestReport() {
        guard FileManager.default.fileExists(atPath: historyStore.reportURL.path) else { return }
        NSWorkspace.shared.open(historyStore.reportURL)
    }

    func revealHistoryFolder() {
        let targetURL = FileManager.default.fileExists(atPath: historyStore.reportURL.path)
            ? historyStore.reportURL
            : historyStore.baseDirectoryURL
        NSWorkspace.shared.activateFileViewerSelecting([targetURL])
    }

    private static func parsePercent(from text: String) -> Double? {
        let cleaned = text
            .replacingOccurrences(of: "%", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Double(cleaned)
    }

    private static func parseWatts(from text: String) -> Double? {
        let cleaned = text
            .replacingOccurrences(of: "W", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Double(cleaned)
    }

    private static func parseUsedTotalPair(from text: String) -> (used: Double?, total: Double?) {
        let parts = text.components(separatedBy: " / ")
        guard parts.count == 2 else {
            return (nil, nil)
        }

        let used = Double(parts[0].trimmingCharacters(in: .whitespacesAndNewlines))
        let total = Double(parts[1].replacingOccurrences(of: " GB", with: "").trimmingCharacters(in: .whitespacesAndNewlines))
        return (used, total)
    }

    private static func parseLoadAverage(from text: String) -> (oneMinute: Double?, fiveMinute: Double?) {
        let parts = text
            .split(separator: ",")
            .map { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        let oneMinute = parts.indices.contains(0) ? parts[0] : nil
        let fiveMinute = parts.indices.contains(1) ? parts[1] : nil
        return (oneMinute, fiveMinute)
    }

    private static func format(timestamp: Date?) -> String {
        guard let timestamp else {
            return "—"
        }

        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: timestamp)
    }
}

/// Uses `getifaddrs` to compute network traffic and derive upload/download speeds.
final class NetworkMonitor {
    private var previousBytesIn: UInt64 = 0
    private var previousBytesOut: UInt64 = 0
    private var previousTime: TimeInterval = Date().timeIntervalSince1970

    init() {
        let totals = Self.getTotalBytes()
        previousBytesIn = totals.inBytes
        previousBytesOut = totals.outBytes
    }

    /// Returns bytes per second for download (inbound) and upload (outbound).
    func currentSpeeds() -> (download: Double, upload: Double) {
        let now = Date().timeIntervalSince1970
        let elapsed = now - previousTime
        guard elapsed > 0 else { return (0, 0) }

        let totals = Self.getTotalBytes()
        
        // Safely compute deltas to avoid arithmetic overflow when counters reset
        // (e.g., after sleep/wake, interface changes, or counter wrap-around)
        let deltaIn: Double
        let deltaOut: Double
        
        if totals.inBytes >= previousBytesIn {
            deltaIn = Double(totals.inBytes - previousBytesIn)
        } else {
            // Counter reset detected, skip this sample
            deltaIn = 0
        }
        
        if totals.outBytes >= previousBytesOut {
            deltaOut = Double(totals.outBytes - previousBytesOut)
        } else {
            // Counter reset detected, skip this sample
            deltaOut = 0
        }

        previousBytesIn = totals.inBytes
        previousBytesOut = totals.outBytes
        previousTime = now

        let downloadBps = max(deltaIn / elapsed, 0)
        let uploadBps = max(deltaOut / elapsed, 0)
        return (downloadBps, uploadBps)
    }

    private static func getTotalBytes() -> (inBytes: UInt64, outBytes: UInt64) {
        var addrsPointer: UnsafeMutablePointer<ifaddrs>?
        var inBytes: UInt64 = 0
        var outBytes: UInt64 = 0

        if getifaddrs(&addrsPointer) == 0, let firstAddr = addrsPointer {
            var ptr: UnsafeMutablePointer<ifaddrs>? = firstAddr
            while let current = ptr {
                let interface = current.pointee

                let flags = Int32(interface.ifa_flags)
                let isUp = (flags & IFF_UP) == IFF_UP
                let isLoopback = (flags & IFF_LOOPBACK) == IFF_LOOPBACK

                if isUp && !isLoopback,
                   let data = unsafeBitCast(interface.ifa_data, to: UnsafeMutablePointer<if_data>?.self) {
                    inBytes += UInt64(data.pointee.ifi_ibytes)
                    outBytes += UInt64(data.pointee.ifi_obytes)
                }

                ptr = interface.ifa_next
            }
            freeifaddrs(addrsPointer)
        }

        return (inBytes, outBytes)
    }
}

// MARK: - Circular Gauge Component

struct CircularGaugeView: View {
    let value: Double // 0.0 to 1.0
    let label: String
    let valueText: String
    let icon: String
    let gradientColors: [Color]
    
    @State private var animatedValue: Double = 0
    
    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                // Background track
                Circle()
                    .stroke(
                        Color.gray.opacity(0.2),
                        lineWidth: 8
                    )
                
                // Progress arc
                Circle()
                    .trim(from: 0, to: animatedValue)
                    .stroke(
                        AngularGradient(
                            colors: gradientColors,
                            center: .center,
                            startAngle: .degrees(0),
                            endAngle: .degrees(360 * animatedValue)
                        ),
                        style: StrokeStyle(lineWidth: 8, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                
                // Center content
                VStack(spacing: 2) {
                    Image(systemName: icon)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(gradientColors.first ?? .blue)
                    Text(valueText)
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .monospacedDigit()
                }
            }
            .frame(width: 70, height: 70)
            
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .onAppear {
            withAnimation(.spring(response: 0.8, dampingFraction: 0.8)) {
                animatedValue = value
            }
        }
        .onChange(of: value) { _, newValue in
            withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                animatedValue = newValue
            }
        }
    }
}

// MARK: - Glassmorphic Card

struct GlassCard<Content: View>: View {
    let content: Content
    
    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }
    
    var body: some View {
        content
            .padding(18)
            .background {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.thinMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(Color.white.opacity(0.14), lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(0.05), radius: 12, x: 0, y: 6)
            }
    }
}

// MARK: - Stat Row

struct StatRow: View {
    let icon: String
    let label: String
    let value: String
    var iconColor: Color = .secondary
    
    @State private var isHovered = false
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(iconColor)
                .frame(width: 24)
            
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            
            Spacer()
            
            Text(value)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.primary)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isHovered ? Color.primary.opacity(0.05) : Color.clear)
        }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - Network Speed Bar

struct NetworkSpeedBar: View {
    let downloadSpeed: String
    let uploadSpeed: String
    
    var body: some View {
        HStack(spacing: 20) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.cyan)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text("Download")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(downloadSpeed)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                }
            }
            
            Spacer()
            
            Rectangle()
                .fill(Color.gray.opacity(0.3))
                .frame(width: 1, height: 30)
            
            Spacer()
            
            HStack(spacing: 8) {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Upload")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(uploadSpeed)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                }
                
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 8)
    }
}

// MARK: - Main Content View

struct ContentView: View {
    @StateObject private var viewModel = SystemInfoViewModel()
    @State private var selectedSection: DashboardSection? = .overview
    @State private var searchText: String = ""

    private var cpuPercent: Double? {
        percentage(from: viewModel.cpuUsage)
    }

    private var cpuValue: Double {
        min(max((cpuPercent ?? 0) / 100, 0), 1)
    }

    private var memoryValue: Double {
        let parts = viewModel.memoryUsage.components(separatedBy: " / ")
        if parts.count == 2,
           let used = Double(parts[0]),
           let total = Double(parts[1].replacingOccurrences(of: " GB", with: "")),
           total > 0 {
            return min(max(used / total, 0), 1)
        }
        return 0
    }

    private var memoryPercent: String {
        String(format: "%.0f%%", memoryValue * 100)
    }

    private var batteryPercent: Double? {
        percentage(from: viewModel.batteryLevel)
    }

    private var batteryValue: Double {
        min(max((batteryPercent ?? 0) / 100, 0), 1)
    }

    private var powerUsageWatts: Double? {
        let cleaned = viewModel.powerUsage
            .replacingOccurrences(of: "W", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Double(cleaned)
    }

    private var powerGaugeValue: Double {
        min(max((powerUsageWatts ?? 0) / 60, 0), 1)
    }

    private var batteryGradient: [Color] {
        if batteryValue < 0.2 {
            return [.red, .orange]
        } else if batteryValue < 0.5 {
            return [.orange, .yellow]
        } else {
            return [.green, .mint]
        }
    }

    private var powerGradient: [Color] {
        if powerGaugeValue > 0.7 {
            return [.red, .orange]
        } else if powerGaugeValue > 0.35 {
            return [.orange, .yellow]
        } else {
            return [.teal, .mint]
        }
    }

    private var diskPercent: String {
        String(format: "%.0f%%", viewModel.diskUsagePercent * 100)
    }

    private var thermalColor: Color {
        switch viewModel.thermalState {
        case "Normal":
            return .green
        case "Fair":
            return .yellow
        case "Serious":
            return .orange
        case "Critical":
            return .red
        default:
            return .gray
        }
    }

    private var healthSummary: DashboardHealthSummary {
        DashboardPresentationBuilder.healthSummary(
            cpuUsagePercent: cpuPercent,
            batteryLevelPercent: batteryPercent,
            thermalState: viewModel.thermalState,
            powerUsageWatts: powerUsageWatts
        )
    }

    private var filteredSections: [DashboardSection] {
        DashboardPresentationBuilder.filteredSections(matching: searchText)
    }

    private var activeSection: DashboardSection? {
        guard !filteredSections.isEmpty else {
            return nil
        }
        if let selectedSection, filteredSections.contains(selectedSection) {
            return selectedSection
        }
        return filteredSections.first
    }

    private var historySubtitle: String {
        DashboardPresentationBuilder.historySubtitle(
            sampleCount: viewModel.historySampleCount,
            coverageText: viewModel.historyCoverage
        )
    }

    private var adaptiveColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 250), spacing: 16, alignment: .top)]
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedSection) {
                Section {
                    DashboardSidebarStatusCard(
                        summary: healthSummary,
                        hostName: viewModel.hostName,
                        macOSVersion: viewModel.macOSVersion,
                        historySubtitle: historySubtitle,
                        accentColor: toneColor(for: healthSummary.tone)
                    )
                    .listRowInsets(EdgeInsets(top: 6, leading: 8, bottom: 10, trailing: 8))
                    .listRowBackground(Color.clear)
                }

                Section("Sections") {
                    if filteredSections.isEmpty {
                        Text("No sections match the current search.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(filteredSections) { section in
                            DashboardSidebarSectionRow(
                                section: section,
                                subtitle: sidebarSubtitle(for: section),
                                accentColor: sectionAccentColor(for: section)
                            )
                            .tag(section)
                        }
                    }
                }

                Section("Monitoring") {
                    LabeledContent("Samples", value: "\(viewModel.historySampleCount)")
                    LabeledContent("Last saved", value: viewModel.lastHistorySave)
                    LabeledContent("Report updated", value: viewModel.lastReportGenerated)
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("System Monitor")
        } detail: {
            Group {
                if let activeSection {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 24) {
                            DashboardHeroCard(
                                summary: healthSummary,
                                hostName: viewModel.hostName,
                                macOSVersion: viewModel.macOSVersion,
                                cpuModel: viewModel.cpuModel,
                                gpuName: viewModel.gpuName,
                                historySubtitle: historySubtitle,
                                lastSaved: viewModel.lastHistorySave,
                                accentColor: toneColor(for: healthSummary.tone)
                            )

                            sectionContent(for: activeSection)
                        }
                        .padding(24)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .navigationTitle(activeSection.title)
                } else {
                    ContentUnavailableView(
                        "No Matching Sections",
                        systemImage: "magnifyingglass",
                        description: Text("Try a broader search to bring the dashboard sections back.")
                    )
                }
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .searchable(text: $searchText, prompt: "Search sections or report")
        .toolbar {
            ToolbarItemGroup {
                Button {
                    viewModel.openLatestReport()
                } label: {
                    Label("Open Report", systemImage: "doc.text")
                }

                Button {
                    viewModel.revealHistoryFolder()
                } label: {
                    Label("Reveal Files", systemImage: "folder")
                }
            }
        }
        .frame(minWidth: 1120, minHeight: 760)
        .onAppear {
            reconcileSelection()
        }
        .onChange(of: searchText) { _, _ in
            reconcileSelection()
        }
    }

    @ViewBuilder
    private func sectionContent(for section: DashboardSection) -> some View {
        switch section {
        case .overview:
            overviewSection
        case .performance:
            performanceSection
        case .power:
            powerSection
        case .network:
            networkSection
        case .history:
            historySection
        }
    }

    private var overviewSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            DashboardSectionHeader(
                title: "At-a-glance health",
                subtitle: "The primary signals you care about, organized as a real dashboard instead of a long dump."
            )

            LazyVGrid(columns: adaptiveColumns, spacing: 16) {
                DashboardGaugeCard(
                    title: "CPU Activity",
                    subtitle: "Delta-based usage from host CPU ticks.",
                    value: cpuValue,
                    label: "CPU",
                    valueText: viewModel.cpuUsage,
                    icon: "cpu.fill",
                    colors: [.blue, .cyan]
                )

                DashboardGaugeCard(
                    title: "Memory Pressure",
                    subtitle: "Working memory versus installed capacity.",
                    value: memoryValue,
                    label: "Memory",
                    valueText: memoryPercent,
                    icon: "memorychip.fill",
                    colors: [.indigo, .blue]
                )

                DashboardGaugeCard(
                    title: "Disk Utilization",
                    subtitle: "Root volume usage based on total versus free space.",
                    value: viewModel.diskUsagePercent,
                    label: "Disk",
                    valueText: diskPercent,
                    icon: "internaldrive.fill",
                    colors: [.orange, .yellow]
                )

                DashboardGaugeCard(
                    title: "Battery Reserve",
                    subtitle: "Battery level and source context.",
                    value: batteryValue,
                    label: "Battery",
                    valueText: viewModel.batteryLevel,
                    icon: "battery.100",
                    colors: batteryGradient
                )
            }

            LazyVGrid(columns: adaptiveColumns, spacing: 16) {
                DashboardFactsCard(
                    title: "Machine Profile",
                    subtitle: "Identity and hardware context for this Mac."
                ) {
                    StatRow(icon: "desktopcomputer", label: "Host", value: viewModel.hostName, iconColor: .teal)
                    StatRow(icon: "applelogo", label: "macOS", value: viewModel.macOSVersion, iconColor: .blue)
                    StatRow(icon: "cpu", label: "CPU", value: viewModel.cpuModel, iconColor: .indigo)
                    StatRow(icon: "square.stack.3d.up.fill", label: "GPU", value: viewModel.gpuName, iconColor: .mint)
                }

                DashboardFactsCard(
                    title: "Operational Snapshot",
                    subtitle: "Live health markers that explain the current state."
                ) {
                    StatRow(icon: "waveform.path.ecg", label: "Load Average", value: viewModel.loadAverage, iconColor: .indigo)
                    StatRow(icon: "thermometer.medium", label: "Thermal State", value: viewModel.thermalState, iconColor: thermalColor)
                    StatRow(icon: "clock.arrow.circlepath", label: "Uptime", value: viewModel.uptime, iconColor: .teal)
                    StatRow(icon: "bolt.badge.clock", label: "Power Usage", value: viewModel.powerUsage, iconColor: .pink)
                }

                historySummaryCard
            }
        }
    }

    private var performanceSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            DashboardSectionHeader(
                title: "Performance signals",
                subtitle: "CPU, memory, disk, and thermal readings presented together so regressions are easier to spot."
            )

            LazyVGrid(columns: adaptiveColumns, spacing: 16) {
                DashboardFactsCard(
                    title: "Processor",
                    subtitle: "Live compute pressure and hardware context."
                ) {
                    StatRow(icon: "cpu.fill", label: "Usage", value: viewModel.cpuUsage, iconColor: .blue)
                    StatRow(icon: "waveform.path.ecg", label: "Load Average", value: viewModel.loadAverage, iconColor: .indigo)
                    StatRow(icon: "cpu", label: "Model", value: viewModel.cpuModel, iconColor: .cyan)
                    StatRow(icon: "square.grid.3x1.below.line.grid.1x2", label: "Cores", value: viewModel.cpuCores, iconColor: .mint)
                }

                DashboardFactsCard(
                    title: "Memory & Storage",
                    subtitle: "Capacity versus free headroom."
                ) {
                    StatRow(icon: "memorychip.fill", label: "Used Memory", value: viewModel.memoryUsage, iconColor: .purple)
                    StatRow(icon: "memorychip", label: "Free Memory", value: viewModel.freeMemory, iconColor: .indigo)
                    StatRow(icon: "internaldrive", label: "Total Disk", value: viewModel.totalDiskSpace, iconColor: .orange)
                    StatRow(icon: "internaldrive.fill", label: "Free Disk", value: viewModel.freeDiskSpace, iconColor: .green)
                }

                DashboardFactsCard(
                    title: "Thermals",
                    subtitle: "Current operating state and the readings around it."
                ) {
                    StatRow(icon: "thermometer.medium", label: "Thermal State", value: viewModel.thermalState, iconColor: thermalColor)
                    StatRow(icon: "clock.arrow.circlepath", label: "Uptime", value: viewModel.uptime, iconColor: .teal)
                    StatRow(icon: "bolt.badge.clock", label: "Power Usage", value: viewModel.powerUsage, iconColor: .pink)
                    StatRow(icon: "desktopcomputer", label: "GPU", value: viewModel.gpuName, iconColor: .mint)
                }
            }
        }
    }

    private var powerSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            DashboardSectionHeader(
                title: "Power center",
                subtitle: "Battery, live wattage, and thermal behavior in one place for a more realistic view of system efficiency."
            )

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 16) {
                    DashboardGaugeCard(
                        title: "Battery Charge",
                        subtitle: "Current reserve level and source context.",
                        value: batteryValue,
                        label: "Battery",
                        valueText: viewModel.batteryLevel,
                        icon: "battery.100",
                        colors: batteryGradient
                    )

                    DashboardGaugeCard(
                        title: "Power Draw",
                        subtitle: "Estimated from the reported voltage and current.",
                        value: powerGaugeValue,
                        label: "Power",
                        valueText: viewModel.powerUsage,
                        icon: "bolt.fill",
                        colors: powerGradient
                    )
                }

                VStack(spacing: 16) {
                    DashboardGaugeCard(
                        title: "Battery Charge",
                        subtitle: "Current reserve level and source context.",
                        value: batteryValue,
                        label: "Battery",
                        valueText: viewModel.batteryLevel,
                        icon: "battery.100",
                        colors: batteryGradient
                    )

                    DashboardGaugeCard(
                        title: "Power Draw",
                        subtitle: "Estimated from the reported voltage and current.",
                        value: powerGaugeValue,
                        label: "Power",
                        valueText: viewModel.powerUsage,
                        icon: "bolt.fill",
                        colors: powerGradient
                    )
                }
            }

            LazyVGrid(columns: adaptiveColumns, spacing: 16) {
                DashboardFactsCard(
                    title: "Power Snapshot",
                    subtitle: "Current battery and charging state."
                ) {
                    StatRow(icon: "battery.100", label: "Battery Level", value: viewModel.batteryLevel, iconColor: batteryGradient.first ?? .green)
                    StatRow(icon: "powerplug", label: "Power Source", value: viewModel.powerSource, iconColor: .yellow)
                    StatRow(icon: "bolt.badge.clock", label: "Power Usage", value: viewModel.powerUsage, iconColor: .pink)
                    StatRow(icon: "bolt.fill", label: "Charge Rate", value: viewModel.chargingWattage, iconColor: .orange)
                }

                DashboardFactsCard(
                    title: "Thermal Context",
                    subtitle: "Signals that often move with battery drain and charger load."
                ) {
                    StatRow(icon: "thermometer.medium", label: "Thermal State", value: viewModel.thermalState, iconColor: thermalColor)
                    StatRow(icon: "cpu.fill", label: "CPU Usage", value: viewModel.cpuUsage, iconColor: .blue)
                    StatRow(icon: "waveform.path.ecg", label: "Load Average", value: viewModel.loadAverage, iconColor: .indigo)
                    StatRow(icon: "clock.arrow.circlepath", label: "Uptime", value: viewModel.uptime, iconColor: .teal)
                }
            }
        }
    }

    private var networkSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            DashboardSectionHeader(
                title: "Network activity",
                subtitle: "Connection identity and throughput are grouped here so you can read network conditions without hunting for them."
            )

            LazyVGrid(columns: adaptiveColumns, spacing: 16) {
                DashboardFactsCard(
                    title: "Connection",
                    subtitle: "Current link identity."
                ) {
                    StatRow(icon: "wifi", label: "Wi-Fi", value: viewModel.wifiNetwork, iconColor: .blue)
                    StatRow(icon: "network", label: "IP Address", value: viewModel.ipAddress, iconColor: .purple)
                    StatRow(icon: "desktopcomputer", label: "Host", value: viewModel.hostName, iconColor: .teal)
                }

                GlassCard {
                    VStack(alignment: .leading, spacing: 12) {
                        DashboardPanelHeader(
                            title: "Throughput",
                            subtitle: "Download and upload speeds sampled once per second."
                        )

                        NetworkSpeedBar(
                            downloadSpeed: viewModel.downloadSpeed,
                            uploadSpeed: viewModel.uploadSpeed
                        )
                    }
                }
            }
        }
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 16) {
            DashboardSectionHeader(
                title: "Historical monitoring",
                subtitle: "Every current stat is persisted periodically and summarized into a Markdown report that you can open or share."
            )

            LazyVGrid(columns: adaptiveColumns, spacing: 16) {
                DashboardFactsCard(
                    title: "Capture Status",
                    subtitle: "Persistence cadence and recent write activity."
                ) {
                    StatRow(icon: "clock.badge.checkmark", label: "Save Cadence", value: "Every 1 min", iconColor: .blue)
                    StatRow(icon: "externaldrive.badge.timemachine", label: "Samples Stored", value: "\(viewModel.historySampleCount)", iconColor: .mint)
                    StatRow(icon: "timeline.selection", label: "Coverage", value: viewModel.historyCoverage, iconColor: .teal)
                    StatRow(icon: "square.and.arrow.down", label: "Last Saved", value: viewModel.lastHistorySave, iconColor: .green)
                }

                DashboardFactsCard(
                    title: "Report",
                    subtitle: "Generated from the saved history."
                ) {
                    StatRow(icon: "doc.text.magnifyingglass", label: "Report Updated", value: viewModel.lastReportGenerated, iconColor: .orange)
                    StatRow(icon: "bolt.badge.clock", label: "Latest Power", value: viewModel.powerUsage, iconColor: .pink)
                    StatRow(icon: "waveform.path.ecg", label: "Latest CPU", value: viewModel.cpuUsage, iconColor: .blue)
                    StatRow(icon: "memorychip.fill", label: "Latest Memory", value: viewModel.memoryUsage, iconColor: .indigo)
                }
            }

            GlassCard {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        DashboardPanelHeader(
                            title: "Markdown Report Preview",
                            subtitle: "Live preview of the report saved in Application Support."
                        )

                        Spacer()

                        HStack(spacing: 10) {
                            Button {
                                viewModel.openLatestReport()
                            } label: {
                                Label("Open Report", systemImage: "doc.text")
                            }
                            .buttonStyle(.borderedProminent)

                            Button {
                                viewModel.revealHistoryFolder()
                            } label: {
                                Label("Reveal Files", systemImage: "folder")
                            }
                            .buttonStyle(.bordered)
                        }
                    }

                    ScrollView {
                        Text(viewModel.latestReportText)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                    }
                    .frame(minHeight: 320)
                    .background {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.primary.opacity(0.045))
                    }
                }
            }
        }
    }

    private var historySummaryCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                DashboardPanelHeader(
                    title: "Monitoring history",
                    subtitle: historySubtitle
                )

                StatRow(icon: "square.and.arrow.down", label: "Last Saved", value: viewModel.lastHistorySave, iconColor: .green)
                StatRow(icon: "doc.text.magnifyingglass", label: "Report Updated", value: viewModel.lastReportGenerated, iconColor: .orange)

                Text(viewModel.latestReportText)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.primary.opacity(0.045))
                    }
            }
        }
    }

    private func sidebarSubtitle(for section: DashboardSection) -> String {
        switch section {
        case .overview:
            return healthSummary.subtitle
        case .performance:
            return "\(viewModel.cpuUsage) CPU • \(memoryPercent) memory"
        case .power:
            return "\(viewModel.powerUsage) • \(viewModel.powerSource)"
        case .network:
            return "\(viewModel.downloadSpeed) down • \(viewModel.uploadSpeed) up"
        case .history:
            return historySubtitle
        }
    }

    private func sectionAccentColor(for section: DashboardSection) -> Color {
        switch section {
        case .overview:
            return .teal
        case .performance:
            return .blue
        case .power:
            return .orange
        case .network:
            return .cyan
        case .history:
            return .green
        }
    }

    private func toneColor(for tone: DashboardTone) -> Color {
        switch tone {
        case .nominal:
            return .teal
        case .elevated:
            return .orange
        case .critical:
            return .red
        }
    }

    private func percentage(from text: String) -> Double? {
        let cleaned = text
            .replacingOccurrences(of: "%", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Double(cleaned)
    }

    private func reconcileSelection() {
        guard !filteredSections.isEmpty else {
            selectedSection = nil
            return
        }

        if let selectedSection, filteredSections.contains(selectedSection) {
            return
        }

        selectedSection = filteredSections.first
    }
}

private struct DashboardSidebarStatusCard: View {
    let summary: DashboardHealthSummary
    let hostName: String
    let macOSVersion: String
    let historySubtitle: String
    let accentColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(accentColor.opacity(0.16))
                        .frame(width: 34, height: 34)

                    Image(systemName: "gauge.with.dots.needle.67percent")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(accentColor)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(summary.title)
                        .font(.system(size: 13, weight: .semibold))
                    Text(hostName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Text(summary.subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(macOSVersion)
                .font(.caption2)
                .foregroundStyle(accentColor)

            Text(historySubtitle)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.regularMaterial)
        }
    }
}

private struct DashboardSidebarSectionRow: View {
    let section: DashboardSection
    let subtitle: String
    let accentColor: Color

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: section.symbolName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(accentColor)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(section.title)
                    .font(.system(size: 13, weight: .semibold))
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct DashboardHeroCard: View {
    let summary: DashboardHealthSummary
    let hostName: String
    let macOSVersion: String
    let cpuModel: String
    let gpuName: String
    let historySubtitle: String
    let lastSaved: String
    let accentColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 18) {
                    heading
                    facts
                }

                VStack(alignment: .leading, spacing: 18) {
                    heading
                    facts
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(summary.highlights, id: \.self) { highlight in
                        Text(highlight)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background {
                                Capsule()
                                    .fill(Color.white.opacity(0.22))
                            }
                    }
                }
            }
        }
        .padding(22)
        .background {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            accentColor.opacity(0.22),
                            Color.teal.opacity(0.08),
                            Color.orange.opacity(0.12)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(.thinMaterial.opacity(0.55))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(Color.white.opacity(0.18), lineWidth: 1)
                }
        }
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("System Monitor")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)

            Text(summary.title)
                .font(.system(size: 28, weight: .bold, design: .rounded))

            Text(summary.subtitle)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var facts: some View {
        VStack(alignment: .leading, spacing: 10) {
            DashboardFactPill(label: "Host", value: hostName, accentColor: accentColor)
            DashboardFactPill(label: "macOS", value: macOSVersion, accentColor: .blue)
            DashboardFactPill(label: "CPU", value: cpuModel, accentColor: .indigo)
            DashboardFactPill(label: "GPU", value: gpuName, accentColor: .mint)
            DashboardFactPill(label: "History", value: historySubtitle, accentColor: .green)
            DashboardFactPill(label: "Last Save", value: lastSaved, accentColor: .orange)
        }
        .frame(maxWidth: 360, alignment: .leading)
    }
}

private struct DashboardFactPill: View {
    let label: String
    let value: String
    let accentColor: Color

    var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(accentColor)
                .frame(width: 62, alignment: .leading)

            Text(value)
                .font(.caption)
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.18))
        }
    }
}

private struct DashboardSectionHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 22, weight: .bold, design: .rounded))

            Text(subtitle)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
    }
}

private struct DashboardPanelHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))

            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct DashboardGaugeCard: View {
    let title: String
    let subtitle: String
    let value: Double
    let label: String
    let valueText: String
    let icon: String
    let colors: [Color]

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                DashboardPanelHeader(title: title, subtitle: subtitle)

                HStack {
                    Spacer(minLength: 0)
                    CircularGaugeView(
                        value: value,
                        label: label,
                        valueText: valueText,
                        icon: icon,
                        gradientColors: colors
                    )
                    Spacer(minLength: 0)
                }
            }
        }
    }
}

private struct DashboardFactsCard<Content: View>: View {
    let title: String
    let subtitle: String
    let content: Content

    init(
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                DashboardPanelHeader(title: title, subtitle: subtitle)
                content
            }
        }
    }
}

#Preview {
    ContentView()
}
