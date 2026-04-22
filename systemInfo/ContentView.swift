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
    @Published var chargingWattage: String = "—"
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
    private var currentPowerSnapshot: PowerTelemetrySnapshot = .unavailable

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
        ipAddress = NetworkDetailsResolver.currentIPv4Address()
        wifiNetwork = NetworkDetailsResolver.currentWiFiSSID()
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
        let snapshot = PowerTelemetryResolver.currentSnapshot()
        currentPowerSnapshot = snapshot
        batteryLevel = snapshot.batteryLevelText
        powerSource = snapshot.powerSource
        powerUsage = snapshot.systemPowerText
        chargingWattage = snapshot.chargeRateText
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
            batteryLevelText: currentPowerSnapshot.batteryLevelText,
            batteryLevelPercent: Self.parsePercent(from: currentPowerSnapshot.batteryLevelText),
            powerSource: currentPowerSnapshot.powerSource,
            powerUsageText: currentPowerSnapshot.systemPowerText,
            powerUsageWatts: currentPowerSnapshot.systemPowerWatts,
            powerMetricKind: currentPowerSnapshot.powerMetricKind,
            powerMetricSource: currentPowerSnapshot.powerMetricSource,
            chargingWattageText: currentPowerSnapshot.chargeRateText,
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
        formatter.setLocalizedDateFormatFromTemplate("MMM d h:mm a")
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
                .frame(width: 86, alignment: .leading)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
            
            Spacer(minLength: 8)
            
            Text(value)
                .font(.system(size: 12.5, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .allowsTightening(true)
                .multilineTextAlignment(.trailing)
                .frame(alignment: .trailing)
                .layoutPriority(1)
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
        HStack(spacing: 18) {
            throughputColumn(
                title: "Download",
                value: downloadSpeed,
                icon: "arrow.down.circle.fill",
                accentColor: .cyan
            )

            Rectangle()
                .fill(Color.gray.opacity(0.22))
                .frame(width: 1, height: 54)

            throughputColumn(
                title: "Upload",
                value: uploadSpeed,
                icon: "arrow.up.circle.fill",
                accentColor: .orange
            )
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 6)
    }

    private func throughputColumn(
        title: String,
        value: String,
        icon: String,
        accentColor: Color
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundStyle(accentColor)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Text(value)
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
                    DashboardSidebarMetricRow(label: "Samples", value: "\(viewModel.historySampleCount)")
                    DashboardSidebarMetricRow(label: "Saved", value: viewModel.lastHistorySave)
                    DashboardSidebarMetricRow(label: "Report", value: viewModel.lastReportGenerated)
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("System Monitor")
            .navigationSplitViewColumnWidth(min: 280, ideal: 300, max: 320)
        } detail: {
            Group {
                if let activeSection {
                    GeometryReader { proxy in
                        let contentWidth = max(proxy.size.width - 40, 320)

                        ScrollView {
                            VStack(alignment: .leading, spacing: 20) {
                                DashboardHeroCard(
                                    summary: healthSummary,
                                    hostName: viewModel.hostName,
                                    macOSVersion: viewModel.macOSVersion,
                                    cpuModel: viewModel.cpuModel,
                                    gpuName: viewModel.gpuName,
                                    historySubtitle: historySubtitle,
                                    lastSaved: viewModel.lastHistorySave,
                                    accentColor: toneColor(for: healthSummary.tone),
                                    showFactsPanel: activeSection == .overview
                                )

                                sectionContent(for: activeSection, availableWidth: contentWidth)
                            }
                            .padding(20)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
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
    private func sectionContent(for section: DashboardSection, availableWidth: CGFloat) -> some View {
        switch section {
        case .overview:
            overviewSection(availableWidth: availableWidth)
        case .performance:
            performanceSection(availableWidth: availableWidth)
        case .power:
            powerSection(availableWidth: availableWidth)
        case .network:
            networkSection(availableWidth: availableWidth)
        case .history:
            historySection(availableWidth: availableWidth)
        }
    }

    private func overviewSection(availableWidth: CGFloat) -> some View {
        let gaugeColumns = gridColumns(for: availableWidth, minimumCardWidth: 280, maxColumns: 3)
        let factsColumns = gridColumns(for: availableWidth, minimumCardWidth: 340, maxColumns: 2)

        return VStack(alignment: .leading, spacing: 16) {
            DashboardSectionHeader(
                title: "At-a-glance health",
                subtitle: "The primary signals you care about, organized as a real dashboard instead of a long dump."
            )

            LazyVGrid(columns: gaugeColumns, spacing: 16) {
                DashboardGaugeCard(
                    title: "CPU Activity",
                    subtitle: "Delta-based usage from host CPU ticks.",
                    value: cpuValue,
                    label: "CPU",
                    valueText: viewModel.cpuUsage,
                    icon: "cpu.fill",
                    colors: [.blue, .cyan],
                    minHeight: 170
                )

                DashboardGaugeCard(
                    title: "Memory Pressure",
                    subtitle: "Working memory versus installed capacity.",
                    value: memoryValue,
                    label: "Memory",
                    valueText: memoryPercent,
                    icon: "memorychip.fill",
                    colors: [.indigo, .blue],
                    minHeight: 170
                )

                DashboardGaugeCard(
                    title: "Disk Utilization",
                    subtitle: "Root volume usage based on total versus free space.",
                    value: viewModel.diskUsagePercent,
                    label: "Disk",
                    valueText: diskPercent,
                    icon: "internaldrive.fill",
                    colors: [.orange, .yellow],
                    minHeight: 170
                )

                DashboardGaugeCard(
                    title: "Battery Reserve",
                    subtitle: "Battery level and source context.",
                    value: batteryValue,
                    label: "Battery",
                    valueText: viewModel.batteryLevel,
                    icon: "battery.100",
                    colors: batteryGradient,
                    minHeight: 170
                )
            }

            LazyVGrid(columns: factsColumns, spacing: 16) {
                DashboardFactsCard(
                    title: "Machine Profile",
                    subtitle: "Identity and hardware context for this Mac.",
                    minHeight: 196
                ) {
                    StatRow(icon: "desktopcomputer", label: "Host", value: viewModel.hostName, iconColor: .teal)
                    StatRow(icon: "applelogo", label: "macOS", value: viewModel.macOSVersion, iconColor: .blue)
                    StatRow(icon: "cpu", label: "CPU", value: viewModel.cpuModel, iconColor: .indigo)
                    StatRow(icon: "square.stack.3d.up.fill", label: "GPU", value: viewModel.gpuName, iconColor: .mint)
                }

                DashboardFactsCard(
                    title: "Operational Snapshot",
                    subtitle: "Live health markers that explain the current state.",
                    minHeight: 196
                ) {
                    StatRow(icon: "waveform.path.ecg", label: "Load Average", value: viewModel.loadAverage, iconColor: .indigo)
                    StatRow(icon: "thermometer.medium", label: "Thermal State", value: viewModel.thermalState, iconColor: thermalColor)
                    StatRow(icon: "clock.arrow.circlepath", label: "Uptime", value: viewModel.uptime, iconColor: .teal)
                    StatRow(icon: "bolt.badge.clock", label: "System Power", value: viewModel.powerUsage, iconColor: .pink)
                }

                historySummaryCard
            }
        }
    }

    private func performanceSection(availableWidth: CGFloat) -> some View {
        let columns = gridColumns(for: availableWidth, minimumCardWidth: 360, maxColumns: 2)

        return VStack(alignment: .leading, spacing: 16) {
            DashboardSectionHeader(
                title: "Performance signals",
                subtitle: "CPU, memory, disk, and thermal readings presented together so regressions are easier to spot."
            )

            LazyVGrid(columns: columns, spacing: 16) {
                DashboardFactsCard(
                    title: "Processor",
                    subtitle: "Live compute pressure and hardware context.",
                    minHeight: 196
                ) {
                    StatRow(icon: "cpu.fill", label: "Usage", value: viewModel.cpuUsage, iconColor: .blue)
                    StatRow(icon: "waveform.path.ecg", label: "Load Average", value: viewModel.loadAverage, iconColor: .indigo)
                    StatRow(icon: "cpu", label: "Model", value: viewModel.cpuModel, iconColor: .cyan)
                    StatRow(icon: "square.grid.3x1.below.line.grid.1x2", label: "Cores", value: viewModel.cpuCores, iconColor: .mint)
                }

                DashboardFactsCard(
                    title: "Memory & Storage",
                    subtitle: "Capacity versus free headroom.",
                    minHeight: 196
                ) {
                    StatRow(icon: "memorychip.fill", label: "Used Memory", value: viewModel.memoryUsage, iconColor: .purple)
                    StatRow(icon: "memorychip", label: "Free Memory", value: viewModel.freeMemory, iconColor: .indigo)
                    StatRow(icon: "internaldrive", label: "Total Disk", value: viewModel.totalDiskSpace, iconColor: .orange)
                    StatRow(icon: "internaldrive.fill", label: "Free Disk", value: viewModel.freeDiskSpace, iconColor: .green)
                }

                DashboardFactsCard(
                    title: "Thermals",
                    subtitle: "Current operating state and the readings around it.",
                    minHeight: 196
                ) {
                    StatRow(icon: "thermometer.medium", label: "Thermal State", value: viewModel.thermalState, iconColor: thermalColor)
                    StatRow(icon: "clock.arrow.circlepath", label: "Uptime", value: viewModel.uptime, iconColor: .teal)
                    StatRow(icon: "bolt.badge.clock", label: "System Power", value: viewModel.powerUsage, iconColor: .pink)
                    StatRow(icon: "desktopcomputer", label: "GPU", value: viewModel.gpuName, iconColor: .mint)
                }
            }
        }
    }

    private func powerSection(availableWidth: CGFloat) -> some View {
        let columns = gridColumns(for: availableWidth, minimumCardWidth: 360, maxColumns: 2)

        return VStack(alignment: .leading, spacing: 16) {
            DashboardSectionHeader(
                title: "Power center",
                subtitle: "Battery state, scoped system-power telemetry, and charging behavior in one place for a clearer view of efficiency."
            )

            LazyVGrid(columns: columns, spacing: 16) {
                DashboardGaugeCard(
                    title: "Battery Charge",
                    subtitle: "Current reserve level and source context.",
                    value: batteryValue,
                    label: "Battery",
                    valueText: viewModel.batteryLevel,
                    icon: "battery.100",
                    colors: batteryGradient,
                    minHeight: 176
                )

                DashboardGaugeCard(
                    title: "System Power",
                    subtitle: "Whole-system draw from AppleSmartBattery telemetry when available.",
                    value: powerGaugeValue,
                    label: "System",
                    valueText: viewModel.powerUsage,
                    icon: "bolt.fill",
                    colors: powerGradient,
                    minHeight: 176
                )
            }

            LazyVGrid(columns: columns, spacing: 16) {
                DashboardFactsCard(
                    title: "Power Snapshot",
                    subtitle: "Current battery state plus separate system-power and charging signals.",
                    minHeight: 196
                ) {
                    StatRow(icon: "battery.100", label: "Battery Level", value: viewModel.batteryLevel, iconColor: batteryGradient.first ?? .green)
                    StatRow(icon: "powerplug", label: "Power Source", value: viewModel.powerSource, iconColor: .yellow)
                    StatRow(icon: "bolt.badge.clock", label: "System Power", value: viewModel.powerUsage, iconColor: .pink)
                    StatRow(icon: "bolt.fill", label: "Battery Charge Rate", value: viewModel.chargingWattage, iconColor: .orange)
                }

                DashboardFactsCard(
                    title: "Thermal Context",
                    subtitle: "Signals that often move with battery drain and charger load.",
                    minHeight: 196
                ) {
                    StatRow(icon: "thermometer.medium", label: "Thermal State", value: viewModel.thermalState, iconColor: thermalColor)
                    StatRow(icon: "cpu.fill", label: "CPU Usage", value: viewModel.cpuUsage, iconColor: .blue)
                    StatRow(icon: "waveform.path.ecg", label: "Load Average", value: viewModel.loadAverage, iconColor: .indigo)
                    StatRow(icon: "clock.arrow.circlepath", label: "Uptime", value: viewModel.uptime, iconColor: .teal)
                }
            }
        }
    }

    private func networkSection(availableWidth: CGFloat) -> some View {
        let columns = gridColumns(for: availableWidth, minimumCardWidth: 360, maxColumns: 2)

        return VStack(alignment: .leading, spacing: 16) {
            DashboardSectionHeader(
                title: "Network activity",
                subtitle: "Connection identity and throughput are grouped here so you can read network conditions without hunting for them."
            )

            LazyVGrid(columns: columns, spacing: 16) {
                DashboardFactsCard(
                    title: "Connection",
                    subtitle: "Current link identity.",
                    minHeight: 176
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
                    .frame(maxWidth: .infinity, minHeight: 176, alignment: .topLeading)
                }
            }
        }
    }

    private func historySection(availableWidth: CGFloat) -> some View {
        let columns = gridColumns(for: availableWidth, minimumCardWidth: 360, maxColumns: 2)

        return VStack(alignment: .leading, spacing: 16) {
            DashboardSectionHeader(
                title: "Historical monitoring",
                subtitle: "Every current stat is persisted periodically and summarized into a Markdown report that you can open or share."
            )

            LazyVGrid(columns: columns, spacing: 16) {
                DashboardFactsCard(
                    title: "Capture Status",
                    subtitle: "Persistence cadence and recent write activity.",
                    minHeight: 188
                ) {
                    StatRow(icon: "clock.badge.checkmark", label: "Save Cadence", value: "Every 1 min", iconColor: .blue)
                    StatRow(icon: "externaldrive.badge.timemachine", label: "Samples Stored", value: "\(viewModel.historySampleCount)", iconColor: .mint)
                    StatRow(icon: "timeline.selection", label: "Coverage", value: viewModel.historyCoverage, iconColor: .teal)
                    StatRow(icon: "square.and.arrow.down", label: "Last Saved", value: viewModel.lastHistorySave, iconColor: .green)
                }

                DashboardFactsCard(
                    title: "Report",
                    subtitle: "Generated from the saved history.",
                    minHeight: 188
                ) {
                    StatRow(icon: "doc.text.magnifyingglass", label: "Report Updated", value: viewModel.lastReportGenerated, iconColor: .orange)
                    StatRow(icon: "bolt.badge.clock", label: "Latest System Power", value: viewModel.powerUsage, iconColor: .pink)
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
        DashboardFactsCard(
            title: "Monitoring history",
            subtitle: historySubtitle,
            minHeight: 228
        ) {
            StatRow(icon: "square.and.arrow.down", label: "Last Saved", value: viewModel.lastHistorySave, iconColor: .green)
            StatRow(icon: "doc.text.magnifyingglass", label: "Report Updated", value: viewModel.lastReportGenerated, iconColor: .orange)

            Text(viewModel.latestReportText)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.primary.opacity(0.045))
                }
        }
    }

    private func sidebarSubtitle(for section: DashboardSection) -> String {
        DashboardPresentationBuilder.compactSectionSummary(
            for: section,
            healthSummary: healthSummary,
            cpuUsageText: viewModel.cpuUsage,
            memoryPercentText: memoryPercent,
            powerUsageText: viewModel.powerUsage,
            powerSource: viewModel.powerSource,
            downloadSpeedText: viewModel.downloadSpeed,
            uploadSpeedText: viewModel.uploadSpeed,
            sampleCount: viewModel.historySampleCount,
            coverageText: viewModel.historyCoverage
        )
    }

    private func gridColumns(for availableWidth: CGFloat, minimumCardWidth: CGFloat, maxColumns: Int) -> [GridItem] {
        let count = DashboardPresentationBuilder.columnCount(
            for: availableWidth,
            minimumCardWidth: minimumCardWidth,
            maxColumns: maxColumns
        )

        return Array(
            repeating: GridItem(.flexible(minimum: 0, maximum: .infinity), spacing: 16, alignment: .top),
            count: count
        )
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
                        .lineLimit(1)
                    Text(hostName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Text(summary.subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Text(macOSVersion)
                .font(.caption2)
                .foregroundStyle(accentColor)
                .lineLimit(1)

            Text(historySubtitle)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
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
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct DashboardSidebarMetricRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 54, alignment: .leading)

            Spacer(minLength: 0)

            Text(value)
                .font(.caption.monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .foregroundStyle(.primary)
        }
        .padding(.vertical, 2)
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
    let showFactsPanel: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: showFactsPanel ? 18 : 12) {
            if showFactsPanel {
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
            } else {
                heading
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
        .padding(showFactsPanel ? 18 : 16)
        .background {
            RoundedRectangle(cornerRadius: showFactsPanel ? 24 : 20, style: .continuous)
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
                    RoundedRectangle(cornerRadius: showFactsPanel ? 24 : 20, style: .continuous)
                        .fill(.thinMaterial.opacity(0.55))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: showFactsPanel ? 24 : 20, style: .continuous)
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
                .font(.system(size: 24, weight: .bold, design: .rounded))

            Text(summary.subtitle)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var facts: some View {
        VStack(alignment: .leading, spacing: 0) {
            DashboardHeroFactRow(label: "Host", value: hostName, accentColor: accentColor)
            Divider().overlay(Color.white.opacity(0.08))
            DashboardHeroFactRow(label: "macOS", value: macOSVersion, accentColor: .blue)
            Divider().overlay(Color.white.opacity(0.08))
            DashboardHeroFactRow(label: "CPU", value: cpuModel, accentColor: .indigo)
            Divider().overlay(Color.white.opacity(0.08))
            DashboardHeroFactRow(label: "GPU", value: gpuName, accentColor: .mint)
            Divider().overlay(Color.white.opacity(0.08))
            DashboardHeroFactRow(label: "History", value: historySubtitle, accentColor: .green)
            Divider().overlay(Color.white.opacity(0.08))
            DashboardHeroFactRow(label: "Last Save", value: lastSaved, accentColor: .orange)
        }
        .frame(maxWidth: 360, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.white.opacity(0.14))
        }
    }
}

private struct DashboardHeroFactRow: View {
    let label: String
    let value: String
    let accentColor: Color

    var body: some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(accentColor)
                .frame(width: 68, alignment: .leading)
                .lineLimit(1)

            Text(value)
                .font(.caption)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.78)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
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
                .lineLimit(2)
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
                .lineLimit(1)

            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, minHeight: 38, alignment: .topLeading)
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
    var minHeight: CGFloat = 170

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
            .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .topLeading)
        }
    }
}

private struct DashboardFactsCard<Content: View>: View {
    let title: String
    let subtitle: String
    let minHeight: CGFloat
    let content: Content

    init(
        title: String,
        subtitle: String,
        minHeight: CGFloat = 196,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.minHeight = minHeight
        self.content = content()
    }

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                DashboardPanelHeader(title: title, subtitle: subtitle)
                content
            }
            .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .topLeading)
        }
    }
}

#Preview {
    ContentView()
}
