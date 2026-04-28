//
//  ContentView.swift
//  systemInfo
//
//  Created by Daniel Ng Zheng Hui on 12/9/25.
//

import SwiftUI
import Charts
import Combine
import Darwin
import AppKit
import UniformTypeIdentifiers

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
    @Published var batteryMaximumCapacity: String = ""
    @Published var batteryTemperature: String = ""
    @Published var batteryCycleCount: String = ""
    @Published var freeMemory: String = ""
    @Published var historySampleCount: Int = 0
    @Published var historyCoverage: String = "0m"
    @Published var lastHistorySave: String = "—"
    @Published var lastReportGenerated: String = "—"
    @Published var latestReportText: String = "Power usage history will appear here once the app captures scoped system-power samples."
    @Published var historySamples: [SystemHistorySample] = []
    @Published var powerUsageReport: PowerUsageReportSnapshot = .empty
    @Published var processRows: [ProcessMonitorRow] = []
    @Published var processLastUpdated: String = "—"
    @Published var processActionMessage: String = ""

    private let networkMonitor = NetworkMonitor()
    private let historyStore = SystemHistoryStore()
    private let processMonitor = ProcessMonitorResolver()
    private var timer: Timer?
    private var lastPersistedAt: Date?
    private var latestDownloadBytesPerSecond: Double = 0
    private var latestUploadBytesPerSecond: Double = 0
    private var currentPowerSnapshot: PowerTelemetrySnapshot = .unavailable

    private let historySaveInterval: TimeInterval = 1
    private let updateQueue = DispatchQueue(label: "com.systemInfo.update", qos: .utility)
    private var cachedTotalDiskBytes: Int64 = 0
    private var tickCount = 0
    private var isRefreshing = false

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
        let (memUsage, freeMemValue) = Self.vmMemorySummaries()
        memoryUsage = memUsage
        freeMemory = freeMemValue
        updatePowerInfo()

        cpuModel = Self.getCPUModel()
        cpuCores = Self.getCPUCores()
        gpuName = Self.getGPUName()
        cachedTotalDiskBytes = getTotalDiskSpaceBytes()
        totalDiskSpace = Self.format(bytes: cachedTotalDiskBytes)
        let freeBytes = getFreeDiskSpaceBytes()
        freeDiskSpace = Self.format(bytes: freeBytes)
        diskUsagePercent = cachedTotalDiskBytes > 0
            ? Double(cachedTotalDiskBytes - freeBytes) / Double(cachedTotalDiskBytes)
            : 0
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
        tickCount += 1
        let tick = tickCount
        guard !isRefreshing else { return }
        isRefreshing = true

        let capturedAt = Date()
        let force = forcePersist
        let totalDisk = cachedTotalDiskBytes

        updateQueue.async { [weak self] in
            guard let self else { return }

            let uptimeValue = Self.format(uptimeSeconds: ProcessInfo.processInfo.systemUptime)
            let (memUsage, freeMemValue) = Self.vmMemorySummaries()
            let cpuValue = Self.cpuUsageSummary()
            let loadValue = Self.loadAverageSummary()
            let thermal = Self.getThermalState()
            let processSnapshot = self.processMonitor.snapshot(capturedAt: capturedAt)

            let speeds = self.networkMonitor.currentSpeeds()
            let dlBps = speeds.download
            let ulBps = speeds.upload

            let freeBytes = self.getFreeDiskSpaceBytes()
            let diskPct = totalDisk > 0 ? Double(totalDisk - freeBytes) / Double(totalDisk) : 0

            // IOKit battery — every 5 s
            let newPowerSnap: PowerTelemetrySnapshot? = tick % 5 == 1
                ? PowerTelemetryResolver.currentSnapshot()
                : nil

            // SCDynamicStore WiFi + IP — every 15 s
            let newIP: String? = tick % 15 == 1 ? NetworkDetailsResolver.currentIPv4Address() : nil
            let newWifi: String? = tick % 15 == 1 ? NetworkDetailsResolver.currentWiFiSSID() : nil

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.uptime = uptimeValue
                self.memoryUsage = memUsage
                self.freeMemory = freeMemValue
                self.cpuUsage = cpuValue
                self.loadAverage = loadValue
                self.thermalState = thermal
                self.processRows = processSnapshot
                self.processLastUpdated = Self.format(timestamp: capturedAt)
                self.latestDownloadBytesPerSecond = dlBps
                self.latestUploadBytesPerSecond = ulBps
                self.downloadSpeed = Self.format(bytesPerSecond: dlBps)
                self.uploadSpeed = Self.format(bytesPerSecond: ulBps)
                self.diskUsagePercent = diskPct
                self.freeDiskSpace = Self.format(bytes: freeBytes)
                if let snap = newPowerSnap {
                    self.currentPowerSnapshot = snap
                    self.batteryLevel = snap.batteryLevelText
                    self.batteryHealth = snap.batteryHealthText
                    self.batteryMaximumCapacity = snap.batteryMaximumCapacityText
                    self.batteryCycleCount = snap.batteryCycleCountText
                    self.powerSource = snap.powerSource
                    self.powerUsage = snap.systemPowerText
                    self.chargingWattage = snap.chargeRateText
                }
                if let ip = newIP { self.ipAddress = ip }
                if let wifi = newWifi { self.wifiNetwork = wifi }
                self.isRefreshing = false
                self.persistHistoryIfNeeded(capturedAt: capturedAt, force: force)
            }
        }
    }

    private func getFreeDiskSpaceBytes() -> Int64 {
        let url = URL(fileURLWithPath: "/")
        if let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let capacity = values.volumeAvailableCapacityForImportantUsage {
            return capacity
        }
        return 0
    }

    /// Single `host_statistics64` call that produces both the "used/total" and "available/total"
    /// memory strings, avoiding the duplicate Mach IPC that the old separate functions incurred.
    private static func vmMemorySummaries() -> (usage: String, free: String) {
        let totalBytes = Double(ProcessInfo.processInfo.physicalMemory)

        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout.size(ofValue: stats) / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, intPtr, &count)
            }
        }

        guard result == KERN_SUCCESS else { return ("—", "—") }

        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)

        let freeBytes = Double(stats.free_count) * Double(pageSize)
        let cacheBytes = Double(stats.inactive_count + stats.speculative_count) * Double(pageSize)
        let usedBytes = max(totalBytes - freeBytes - cacheBytes, 0)
        let availableBytes = freeBytes + cacheBytes

        let totalGB = totalBytes / 1_073_741_824
        let usage = String(format: "%.1f / %.1f GB", usedBytes / 1_073_741_824, totalGB)
        let free  = String(format: "%.1f / %.1f GB", availableBytes / 1_073_741_824, totalGB)
        return (usage, free)
    }

    private func updatePowerInfo() {
        let snapshot = PowerTelemetryResolver.currentSnapshot()
        currentPowerSnapshot = snapshot
        batteryLevel = snapshot.batteryLevelText
        batteryHealth = snapshot.batteryHealthText
        batteryMaximumCapacity = snapshot.batteryMaximumCapacityText
        batteryCycleCount = snapshot.batteryCycleCountText
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
    
    private func hydrateHistory() {
        do {
            let samples = try historyStore.loadSamples()
            updateHistoryMetadata(with: samples)
            updatePowerReportSummary(with: samples)

            if let report = try historyStore.loadPowerReport() {
                latestReportText = report
                lastReportGenerated = Self.format(timestamp: Date())
            } else if !samples.isEmpty {
                let report = try historyStore.refreshPowerReport(using: samples, generatedAt: Date())
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
            let report = try historyStore.refreshPowerReport(using: samples, generatedAt: capturedAt)

            lastPersistedAt = capturedAt
            lastHistorySave = Self.format(timestamp: capturedAt)
            lastReportGenerated = Self.format(timestamp: capturedAt)
            latestReportText = report
            updateHistoryMetadata(with: samples)
            updatePowerReportSummary(with: samples)
        } catch {
            latestReportText = "Unable to persist monitoring history: \(error.localizedDescription)"
        }
    }

    private func updateHistoryMetadata(with samples: [SystemHistorySample]) {
        historySamples = samples
        let overview = historyStore.overview(for: samples)
        historySampleCount = overview.sampleCount
        historyCoverage = overview.coverageText

        if let lastCapturedAt = samples.last?.capturedAt, lastHistorySave == "—" {
            lastHistorySave = Self.format(timestamp: lastCapturedAt)
        }
    }

    private func updatePowerReportSummary(with samples: [SystemHistorySample]) {
        powerUsageReport = PowerUsageReportBuilder.build(from: samples)
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
            totalDiskBytes: cachedTotalDiskBytes,
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

    func regeneratePowerReport() {
        do {
            let samples = try historyStore.loadSamples()
            updateHistoryMetadata(with: samples)
            updatePowerReportSummary(with: samples)

            let generatedAt = Date()
            let report = try historyStore.refreshPowerReport(using: samples, generatedAt: generatedAt)
            latestReportText = report
            lastReportGenerated = Self.format(timestamp: generatedAt)
        } catch {
            latestReportText = "Unable to generate power report: \(error.localizedDescription)"
        }
    }

    func exportPowerReport() {
        do {
            let samples = try historyStore.loadSamples()
            updateHistoryMetadata(with: samples)
            updatePowerReportSummary(with: samples)

            let generatedAt = Date()
            let report = try historyStore.refreshPowerReport(using: samples, generatedAt: generatedAt)
            latestReportText = report
            lastReportGenerated = Self.format(timestamp: generatedAt)

            let savePanel = NSSavePanel()
            savePanel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
            savePanel.canCreateDirectories = true
            savePanel.nameFieldStringValue = Self.exportReportFileName(for: generatedAt)

            guard savePanel.runModal() == .OK, let destinationURL = savePanel.url else {
                return
            }

            try report.write(to: destinationURL, atomically: true, encoding: .utf8)
            NSWorkspace.shared.activateFileViewerSelecting([destinationURL])
        } catch {
            latestReportText = "Unable to export power report: \(error.localizedDescription)"
        }
    }

    func resetHistory() {
        do {
            try historyStore.clearHistory()
        } catch {
            latestReportText = "Unable to reset history: \(error.localizedDescription)"
            return
        }

        lastPersistedAt = nil
        historySamples = []
        historySampleCount = 0
        historyCoverage = "0m"
        lastHistorySave = "—"
        lastReportGenerated = "—"
        powerUsageReport = .empty
        latestReportText = "History cleared. New samples will appear here once the app captures scoped system-power readings."
    }

    func terminateProcess(_ row: ProcessMonitorRow, signal: ProcessSignal) {
        updateQueue.async { [weak self] in
            let result = ProcessTerminator.terminate(processID: row.processID, signal: signal)
            let refreshedRows = self?.processMonitor.snapshot(capturedAt: Date()) ?? []

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.processActionMessage = result.message
                self.processRows = refreshedRows
                self.processLastUpdated = Self.format(timestamp: Date())
            }
        }
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

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMM d h:mm a")
        return f
    }()

    private static let exportFilenameFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .autoupdatingCurrent
        f.dateFormat = "yyyy-MM-dd-HHmm"
        return f
    }()

    private static func format(timestamp: Date?) -> String {
        guard let timestamp else { return "—" }
        return timestampFormatter.string(from: timestamp)
    }

    private static func exportReportFileName(for date: Date) -> String {
        return "power-usage-report-\(exportFilenameFormatter.string(from: date)).md"
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

enum TrendTimeWindow: String, CaseIterable, Identifiable {
    case oneMinute = "1m"
    case fiveMinutes = "5m"
    case fifteenMinutes = "15m"
    case thirtyMinutes = "30m"
    case oneHour = "1hr"
    case fourHours = "4hr"
    case eightHours = "8hr"
    case twelveHours = "12hr"
    case oneDay = "1 day"

    var id: String { rawValue }

    var label: String { rawValue }

    var sampleLimit: Int {
        switch self {
        case .oneMinute: return 60
        case .fiveMinutes: return 300
        case .fifteenMinutes: return 900
        case .thirtyMinutes: return 1800
        case .oneHour: return 3600
        case .fourHours: return 14400
        case .eightHours: return 28800
        case .twelveHours: return 43200
        case .oneDay: return 86400
        }
    }
}

// MARK: - Main Content View

struct ContentView: View {
    @StateObject private var viewModel = SystemInfoViewModel()
    @State private var selectedSection: DashboardSection? = .overview
    @State private var searchText: String = ""
    @State private var showResetConfirmation = false
    @State private var processSearchText: String = ""
    @State private var selectedProcessID: pid_t?
    @State private var processSort = ProcessTableSort.defaultSort
    @State private var pendingForceKillProcess: ProcessMonitorRow?
    @AppStorage("trendTimeWindow") private var selectedTrendWindow: TrendTimeWindow = .fiveMinutes

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

    private var displayedTrendSamples: [SystemHistorySample] {
        DashboardPresentationBuilder.recentSamples(viewModel.historySamples, limit: selectedTrendWindow.sampleLimit)
    }

    private var powerReportTrendCards: [DashboardTrendCardModel] {
        DashboardPresentationBuilder.powerTrendCards(from: viewModel.historySamples, limit: selectedTrendWindow.sampleLimit)
    }

    private var resourceTrendCards: [DashboardTrendCardModel] {
        DashboardPresentationBuilder.resourceTrendCards(from: viewModel.historySamples, limit: selectedTrendWindow.sampleLimit)
    }

    private var trendWindowSubtitle: String {
        DashboardPresentationBuilder.trendWindowSubtitle(
            totalSampleCount: viewModel.historySampleCount,
            displayedSampleCount: displayedTrendSamples.count
        )
    }

    private var displayedProcessRows: [ProcessMonitorRow] {
        ProcessMonitorPresenter.displayRows(
            viewModel.processRows,
            query: processSearchText,
            sort: processSort
        )
    }

    private var selectedProcess: ProcessMonitorRow? {
        guard let selectedProcessID else {
            return displayedProcessRows.first
        }

        return viewModel.processRows.first { $0.processID == selectedProcessID }
    }

    private var isForceKillConfirmationPresented: Binding<Bool> {
        Binding(
            get: { pendingForceKillProcess != nil },
            set: { isPresented in
                if !isPresented {
                    pendingForceKillProcess = nil
                }
            }
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
        .alert(
            "Force Kill Process?",
            isPresented: isForceKillConfirmationPresented,
            presenting: pendingForceKillProcess
        ) { process in
            Button("Force Kill", role: .destructive) {
                viewModel.terminateProcess(process, signal: .forceKill)
                pendingForceKillProcess = nil
            }
            Button("Cancel", role: .cancel) {
                pendingForceKillProcess = nil
            }
        } message: { process in
            Text("\(process.name) (PID \(process.processID)) will receive SIGKILL.")
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
        case .processes:
            processesSection(availableWidth: availableWidth)
        case .history:
            historySection(availableWidth: availableWidth)
        case .trends:
            trendsSection(availableWidth: availableWidth)
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
                    minHeight: 260
                ) {
                    StatRow(icon: "battery.100", label: "Battery Level", value: viewModel.batteryLevel, iconColor: batteryGradient.first ?? .green)
                    StatRow(icon: "heart.text.square", label: "Battery Health", value: viewModel.batteryHealth, iconColor: .mint)
                    StatRow(icon: "gauge.with.dots.needle.bottom.50percent", label: "Max Capacity", value: viewModel.batteryMaximumCapacity, iconColor: .green)
                    StatRow(icon: "repeat.circle", label: "Cycle Count", value: viewModel.batteryCycleCount, iconColor: .cyan)
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

    private func processesSection(availableWidth: CGFloat) -> some View {
        let rows = displayedProcessRows
        let detail = ProcessDetailCard(
            process: selectedProcess,
            actionMessage: viewModel.processActionMessage,
            onTerminate: { process in
                viewModel.terminateProcess(process, signal: .terminate)
            },
            onForceKill: { process in
                pendingForceKillProcess = process
            }
        )

        return VStack(alignment: .leading, spacing: 16) {
            DashboardSectionHeader(
                title: "Process monitor",
                subtitle: "Live per-process CPU, memory, owner, state, executable path, and local process controls."
            )

            GlassCard {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 12) {
                        Label("\(viewModel.processRows.count) processes", systemImage: "list.bullet.rectangle.portrait")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.pink)

                        Text("Updated \(viewModel.processLastUpdated)")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Spacer(minLength: 12)

                        TextField("Search name, PID, or path", text: $processSearchText)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: min(max(availableWidth * 0.32, 260), 420))
                    }

                    if rows.count != viewModel.processRows.count {
                        Text("\(rows.count) matching processes")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if availableWidth < 1_050 {
                VStack(alignment: .leading, spacing: 16) {
                    ProcessMonitorTable(
                        rows: rows,
                        selectedProcessID: $selectedProcessID,
                        sort: $processSort,
                        onTerminate: { process in
                            viewModel.terminateProcess(process, signal: .terminate)
                        },
                        onForceKill: { process in
                            pendingForceKillProcess = process
                        }
                    )
                    detail
                }
            } else {
                HStack(alignment: .top, spacing: 16) {
                    ProcessMonitorTable(
                        rows: rows,
                        selectedProcessID: $selectedProcessID,
                        sort: $processSort,
                        onTerminate: { process in
                            viewModel.terminateProcess(process, signal: .terminate)
                        },
                        onForceKill: { process in
                            pendingForceKillProcess = process
                        }
                    )
                    .frame(maxWidth: .infinity)

                    detail
                        .frame(width: 340)
                }
            }
        }
    }

    private func historySection(availableWidth: CGFloat) -> some View {
        let columns = gridColumns(for: availableWidth, minimumCardWidth: 360, maxColumns: 2)
        let report = viewModel.powerUsageReport

        return VStack(alignment: .leading, spacing: 16) {
            DashboardSectionHeader(
                title: "Monitoring history",
                subtitle: "Saved samples are summarized here so you can review power, memory, CPU load, and bandwidth trends from local data."
            )

            LazyVGrid(columns: columns, spacing: 16) {
                DashboardFactsCard(
                    title: "Report Overview",
                    subtitle: "Scoped power readings derived from the saved monitoring history.",
                    minHeight: 188
                ) {
                    StatRow(icon: "clock.badge.checkmark", label: "Save Cadence", value: "Every 1 min", iconColor: .blue)
                    StatRow(icon: "externaldrive.badge.timemachine", label: "Saved Samples", value: "\(viewModel.historySampleCount)", iconColor: .mint)
                    StatRow(icon: "bolt.badge.clock", label: "Power Samples", value: "\(report.powerSampleCount)", iconColor: .pink)
                    StatRow(icon: "timeline.selection", label: "Coverage", value: report.coverageText, iconColor: .teal)
                    StatRow(icon: "square.and.arrow.down", label: "Last Saved", value: viewModel.lastHistorySave, iconColor: .green)
                }

                DashboardFactsCard(
                    title: "Power Summary",
                    subtitle: "Quick read on the stored power window.",
                    minHeight: 188
                ) {
                    StatRow(icon: "doc.text.magnifyingglass", label: "Report Updated", value: viewModel.lastReportGenerated, iconColor: .orange)
                    StatRow(icon: "bolt.fill", label: "Average Draw", value: formattedWatts(report.averageWatts), iconColor: .pink)
                    StatRow(icon: "waveform.path.ecg", label: "Peak Draw", value: formattedWatts(report.maximumWatts), iconColor: .red)
                    StatRow(icon: "arrow.forward.to.line", label: "Latest Draw", value: formattedWatts(report.latestWatts), iconColor: .orange)
                }

                DashboardFactsCard(
                    title: "Battery & Trend",
                    subtitle: "How the saved power window moved over time.",
                    minHeight: 188
                ) {
                    StatRow(icon: "chart.line.uptrend.xyaxis", label: "Trend", value: trendText(for: report), iconColor: trendColor(for: report))
                    StatRow(icon: "arrow.left.and.right", label: "Trend Delta", value: formattedSignedWatts(report.trendDeltaWatts), iconColor: trendColor(for: report))
                    StatRow(icon: "battery.75", label: "Avg Battery", value: formattedPercent(report.averageBatteryPercent), iconColor: .green)
                    StatRow(icon: "battery.25", label: "Battery Delta", value: formattedSignedPercent(report.batteryDeltaPercent), iconColor: .yellow)
                }

                DashboardFactsCard(
                    title: "Source Mix",
                    subtitle: "Power sources seen in the scoped history.",
                    minHeight: 188
                ) {
                    if report.powerSourceBreakdown.isEmpty {
                        StatRow(icon: "powerplug", label: "Sources", value: "Need more saved power samples", iconColor: .secondary)
                    } else {
                        ForEach(report.powerSourceBreakdown) { source in
                            StatRow(
                                icon: source.label == "AC Power" ? "powerplug.fill" : "battery.100",
                                label: source.label,
                                value: String(format: "%.0f%% · %d", source.share * 100, source.count),
                                iconColor: source.label == "AC Power" ? .yellow : .green
                            )
                        }
                    }
                }
            }

            GlassCard {
                VStack(alignment: .leading, spacing: 14) {
                    DashboardPanelHeader(
                        title: "Peak Moments",
                        subtitle: "Highest recorded system-power readings from the saved local history."
                    )

                    if report.peakMoments.isEmpty {
                        ContentUnavailableView(
                            "No Peak Moments Yet",
                            systemImage: "bolt.slash",
                            description: Text("Scoped system-power samples will populate this list automatically as they are saved.")
                        )
                        .frame(maxWidth: .infinity, minHeight: 160)
                    } else {
                        VStack(spacing: 10) {
                            ForEach(report.peakMoments) { moment in
                                HStack(spacing: 12) {
                                    Text(PowerUsageReportBuilder.displayTimestamp(for: moment.capturedAt, includeDate: true))
                                        .font(.system(size: 12, weight: .medium, design: .rounded))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 130, alignment: .leading)

                                    Text(String(format: "%.1f W", moment.watts))
                                        .font(.system(size: 15, weight: .bold, design: .rounded))
                                        .monospacedDigit()
                                        .frame(width: 86, alignment: .leading)

                                    Text(moment.batteryLevelPercent.map { String(format: "%.0f%%", $0) } ?? "—")
                                        .font(.system(size: 12, weight: .medium, design: .rounded))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 54, alignment: .leading)

                                    Text(moment.powerSource)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(moment.powerSource == "AC Power" ? .yellow : .green)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .background {
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .fill(Color.primary.opacity(0.04))
                                }
                            }
                        }
                    }
                }
            }

            GlassCard {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        DashboardPanelHeader(
                            title: "Markdown Artifact",
                            subtitle: "Generate, preview, and export the saved power usage report."
                        )

                        Spacer()

                        HStack(spacing: 10) {
                            Button {
                                viewModel.regeneratePowerReport()
                            } label: {
                                Label("Generate", systemImage: "arrow.clockwise")
                            }
                            .buttonStyle(.borderedProminent)

                            Button {
                                viewModel.exportPowerReport()
                            } label: {
                                Label("Export", systemImage: "square.and.arrow.up")
                            }
                            .buttonStyle(.bordered)

                            Button {
                                viewModel.openLatestReport()
                            } label: {
                                Label("Open Report", systemImage: "doc.text")
                            }
                            .buttonStyle(.bordered)

                            Button {
                                viewModel.revealHistoryFolder()
                            } label: {
                                Label("Reveal Files", systemImage: "folder")
                            }
                            .buttonStyle(.bordered)

                            Button(role: .destructive) {
                                showResetConfirmation = true
                            } label: {
                                Label("Reset History", systemImage: "trash")
                            }
                            .buttonStyle(.bordered)
                            .confirmationDialog(
                                "Reset all monitoring history?",
                                isPresented: $showResetConfirmation,
                                titleVisibility: .visible
                            ) {
                                Button("Reset History", role: .destructive) {
                                    viewModel.resetHistory()
                                }
                                Button("Cancel", role: .cancel) {}
                            } message: {
                                Text("This permanently deletes all saved samples and the power report. New data will be collected immediately.")
                            }
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

    private func trendsSection(availableWidth: CGFloat) -> some View {
        let chartColumns = gridColumns(for: availableWidth, minimumCardWidth: 320, maxColumns: 3)
        let report = viewModel.powerUsageReport

        return VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                DashboardSectionHeader(
                    title: "Trend analysis",
                    subtitle: "Visual charts for power, memory, CPU load, and bandwidth across recent samples."
                )
                
                Spacer()
                
                Picker("", selection: $selectedTrendWindow) {
                    ForEach(TrendTimeWindow.allCases) { window in
                        Text(window.label).tag(window)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 100)
                .padding(.trailing, 14)
                .padding(.top, 10)
            }

            GlassCard {
                VStack(alignment: .leading, spacing: 16) {
                    DashboardPanelHeader(
                        title: "Power Trends",
                        subtitle: powerTrendSubtitle(report: report)
                    )

                    if powerReportTrendCards.isEmpty {
                        ContentUnavailableView(
                            "Power Trends Need More History",
                            systemImage: "bolt.badge.clock",
                            description: Text("Keep the app open long enough to capture a couple of scoped system-power samples and the report charts will populate here.")
                        )
                        .frame(maxWidth: .infinity, minHeight: 220)
                    } else {
                        LazyVGrid(columns: chartColumns, spacing: 16) {
                            ForEach(powerReportTrendCards) { card in
                                DashboardTrendCard(card: card)
                            }
                        }
                    }
                }
            }

            GlassCard {
                VStack(alignment: .leading, spacing: 16) {
                    DashboardPanelHeader(
                        title: "Resource Trends",
                        subtitle: resourceTrendSubtitle
                    )

                    if resourceTrendCards.isEmpty {
                        ContentUnavailableView(
                            "Resource Trends Need More History",
                            systemImage: "chart.xyaxis.line",
                            description: Text("Keep the app open long enough to capture a couple of saved samples and the memory, CPU load, and bandwidth charts will populate here.")
                        )
                        .frame(maxWidth: .infinity, minHeight: 220)
                    } else {
                        LazyVGrid(columns: chartColumns, spacing: 16) {
                            ForEach(resourceTrendCards) { card in
                                DashboardTrendCard(card: card)
                            }
                        }
                    }
                }
            }
        }
    }

    private var historySummaryCard: some View {
        DashboardFactsCard(
            title: "Power report",
            subtitle: historySubtitle,
            minHeight: 228
        ) {
            StatRow(icon: "square.and.arrow.down", label: "Last Saved", value: viewModel.lastHistorySave, iconColor: .green)
            StatRow(icon: "doc.text.magnifyingglass", label: "Report Updated", value: viewModel.lastReportGenerated, iconColor: .orange)
            StatRow(icon: "bolt.badge.clock", label: "Power Samples", value: "\(viewModel.powerUsageReport.powerSampleCount)", iconColor: .pink)
            StatRow(icon: "chart.line.uptrend.xyaxis", label: "Avg Draw", value: formattedWatts(viewModel.powerUsageReport.averageWatts), iconColor: .teal)

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
            coverageText: viewModel.historyCoverage,
            processCount: viewModel.processRows.count,
            processStatusText: viewModel.processLastUpdated
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
        case .processes:
            return .pink
        case .history:
            return .green
        case .trends:
            return .indigo
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

    private func formattedWatts(_ watts: Double?) -> String {
        guard let watts else {
            return "—"
        }
        return String(format: "%.1f W", watts)
    }

    private func formattedPercent(_ percent: Double?) -> String {
        guard let percent else {
            return "—"
        }
        return String(format: "%.1f%%", percent)
    }

    private func formattedSignedPercent(_ percent: Double?) -> String {
        guard let percent else {
            return "—"
        }
        return percent >= 0
            ? String(format: "+%.1f%%", percent)
            : String(format: "%.1f%%", percent)
    }

    private func formattedSignedWatts(_ watts: Double?) -> String {
        guard let watts else {
            return "—"
        }
        return watts >= 0
            ? String(format: "+%.1f W", watts)
            : String(format: "%.1f W", watts)
    }

    private func trendText(for report: PowerUsageReportSnapshot) -> String {
        report.trendDirection.title
    }

    private func trendColor(for report: PowerUsageReportSnapshot) -> Color {
        switch report.trendDirection {
        case .rising:
            return .orange
        case .falling:
            return .teal
        case .stable:
            return .blue
        case .unavailable:
            return .secondary
        }
    }

    private func powerTrendSubtitle(report: PowerUsageReportSnapshot) -> String {
        guard report.powerSampleCount > 0 else {
            return "Charts will appear after enough scoped system-power history accumulates."
        }

        if powerReportTrendCards.isEmpty {
            return "Saved samples exist, but the report needs more scoped power points to draw the charts."
        }

        let noun = report.powerSampleCount == 1 ? "sample" : "samples"
        return "Showing \(report.powerSampleCount) scoped power \(noun) across \(report.coverageText)."
    }

    private var resourceTrendSubtitle: String {
        guard viewModel.historySampleCount > 0 else {
            return "Charts will appear after enough saved history accumulates."
        }

        if resourceTrendCards.isEmpty {
            return "Saved samples exist, but more history is needed before memory, CPU load, and bandwidth trends can be drawn."
        }

        return trendWindowSubtitle
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

private enum ProcessTableColumn: String, CaseIterable, Identifiable {
    case name, pid, actions, user, cpu, memory, state, path

    var id: String { rawValue }

    var defaultWidth: CGFloat {
        switch self {
        case .name: return 180
        case .pid: return 72
        case .actions: return 116
        case .user: return 88
        case .cpu: return 80
        case .memory: return 110
        case .state: return 100
        case .path: return 318
        }
    }

    var minimumWidth: CGFloat {
        switch self {
        case .name: return 110
        case .pid: return 56
        case .actions: return 110
        case .user: return 56
        case .cpu: return 56
        case .memory: return 72
        case .state: return 64
        case .path: return 140
        }
    }

    var maximumWidth: CGFloat {
        switch self {
        case .actions: return 180
        default: return 800
        }
    }

    static var defaultWidths: [ProcessTableColumn: CGFloat] {
        Dictionary(uniqueKeysWithValues: ProcessTableColumn.allCases.map { ($0, $0.defaultWidth) })
    }
}

private struct ProcessMonitorTable: View {
    let rows: [ProcessMonitorRow]
    @Binding var selectedProcessID: pid_t?
    @Binding var sort: ProcessTableSort
    let onTerminate: (ProcessMonitorRow) -> Void
    let onForceKill: (ProcessMonitorRow) -> Void

    @State private var columnWidths: [ProcessTableColumn: CGFloat] = ProcessTableColumn.defaultWidths

    private var tableWidth: CGFloat {
        ProcessTableColumn.allCases.reduce(0) { partial, column in
            partial + (columnWidths[column] ?? column.defaultWidth) + 16
        }
    }

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                DashboardPanelHeader(
                    title: "Process Table",
                    subtitle: "Sorted by memory by default; drag the dividers between headers to resize columns."
                )

                ScrollView([.horizontal, .vertical]) {
                    VStack(alignment: .leading, spacing: 0) {
                        ProcessTableHeader(sort: $sort, columnWidths: $columnWidths)
                        Divider()
                            .padding(.vertical, 4)

                        if rows.isEmpty {
                            ContentUnavailableView(
                                "No Processes Found",
                                systemImage: "magnifyingglass",
                                description: Text("Try a broader process search.")
                            )
                            .frame(width: tableWidth, height: 360)
                        } else {
                            LazyVStack(alignment: .leading, spacing: 2) {
                                ForEach(rows) { row in
                                    Button {
                                        selectedProcessID = row.processID
                                    } label: {
                                        ProcessTableRow(
                                            row: row,
                                            isSelected: selectedProcessID == row.processID,
                                            columnWidths: columnWidths,
                                            onTerminate: { onTerminate(row) },
                                            onForceKill: { onForceKill(row) }
                                        )
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    .frame(minWidth: tableWidth, alignment: .topLeading)
                }
                .frame(maxWidth: .infinity, minHeight: 460, maxHeight: 520, alignment: .topLeading)
            }
        }
    }
}

private struct ProcessTableHeader: View {
    @Binding var sort: ProcessTableSort
    @Binding var columnWidths: [ProcessTableColumn: CGFloat]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(ProcessTableColumn.allCases) { column in
                headerCell(for: column)
                    .overlay(alignment: .trailing) {
                        ColumnResizeHandle(
                            width: binding(for: column),
                            minimumWidth: column.minimumWidth,
                            maximumWidth: column.maximumWidth
                        )
                    }
            }
        }
        .frame(height: 28)
    }

    private func width(for column: ProcessTableColumn) -> CGFloat {
        columnWidths[column] ?? column.defaultWidth
    }

    private func binding(for column: ProcessTableColumn) -> Binding<CGFloat> {
        Binding(
            get: { columnWidths[column] ?? column.defaultWidth },
            set: { columnWidths[column] = $0 }
        )
    }

    @ViewBuilder
    private func headerCell(for column: ProcessTableColumn) -> some View {
        let columnWidth = width(for: column)
        switch column {
        case .name:
            ProcessTableHeaderButton(title: "Name", key: .name, width: columnWidth, sort: $sort)
        case .pid:
            ProcessTableHeaderButton(title: "PID", key: .processID, width: columnWidth, alignment: .trailing, sort: $sort)
        case .actions:
            ProcessTableHeaderText(title: "Actions", width: columnWidth, alignment: .center)
        case .user:
            ProcessTableHeaderButton(title: "User", key: .user, width: columnWidth, sort: $sort)
        case .cpu:
            ProcessTableHeaderButton(title: "CPU", key: .cpu, width: columnWidth, alignment: .trailing, sort: $sort)
        case .memory:
            ProcessTableHeaderButton(title: "Memory", key: .memory, width: columnWidth, alignment: .trailing, sort: $sort)
        case .state:
            ProcessTableHeaderText(title: "State", width: columnWidth)
        case .path:
            ProcessTableHeaderText(title: "Executable Path", width: columnWidth)
        }
    }
}

private struct ColumnResizeHandle: View {
    @Binding var width: CGFloat
    let minimumWidth: CGFloat
    let maximumWidth: CGFloat

    @State private var dragStartWidth: CGFloat?
    @State private var isHovering = false

    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .contentShape(Rectangle())
            .frame(width: 8)
            .overlay {
                Rectangle()
                    .fill(Color.primary.opacity(isActive ? 0.45 : 0.0))
                    .frame(width: 2, height: 18)
            }
            .onHover { hovering in
                isHovering = hovering
                if hovering {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if dragStartWidth == nil {
                            dragStartWidth = width
                        }
                        let proposed = (dragStartWidth ?? width) + value.translation.width
                        width = min(maximumWidth, max(minimumWidth, proposed))
                    }
                    .onEnded { _ in
                        dragStartWidth = nil
                    }
            )
    }

    private var isActive: Bool {
        isHovering || dragStartWidth != nil
    }
}

private struct ProcessTableHeaderButton: View {
    let title: String
    let key: ProcessTableSortKey
    let width: CGFloat
    var alignment: Alignment = .leading
    @Binding var sort: ProcessTableSort

    var body: some View {
        Button {
            sort = sort.toggled(for: key)
        } label: {
            HStack(spacing: 4) {
                Text(title)
                    .lineLimit(1)
                Image(systemName: sortIcon)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(sort.key == key ? .pink : .secondary)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(width: width, alignment: alignment)
            .padding(.horizontal, 8)
        }
        .buttonStyle(.plain)
    }

    private var sortIcon: String {
        guard sort.key == key else {
            return "arrow.up.arrow.down"
        }
        return sort.direction == .ascending ? "chevron.up" : "chevron.down"
    }
}

private struct ProcessTableHeaderText: View {
    let title: String
    let width: CGFloat
    var alignment: Alignment = .leading

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(width: width, alignment: alignment)
            .padding(.horizontal, 8)
    }
}

private struct ProcessTableRow: View {
    let row: ProcessMonitorRow
    let isSelected: Bool
    let columnWidths: [ProcessTableColumn: CGFloat]
    let onTerminate: () -> Void
    let onForceKill: () -> Void

    private func width(for column: ProcessTableColumn) -> CGFloat {
        columnWidths[column] ?? column.defaultWidth
    }

    private var pathDisplayLength: Int {
        max(20, Int(width(for: .path) / 5.5))
    }

    var body: some View {
        HStack(spacing: 0) {
            ProcessTableCell(text: row.name, width: width(for: .name), weight: .semibold)
            ProcessTableCell(text: "\(row.processID)", width: width(for: .pid), alignment: .trailing, monospaced: true)
            ProcessTableActionsCell(
                width: width(for: .actions),
                onTerminate: onTerminate,
                onForceKill: onForceKill
            )
            ProcessTableCell(text: row.userName, width: width(for: .user))
            ProcessTableCell(text: row.cpuText, width: width(for: .cpu), alignment: .trailing, monospaced: true)
            ProcessTableCell(text: row.memoryText, width: width(for: .memory), alignment: .trailing, monospaced: true)
            ProcessTableCell(text: row.state, width: width(for: .state))
            ProcessTableCell(
                text: ProcessMonitorPresenter.truncatedPath(row.executablePathText, maxLength: pathDisplayLength),
                width: width(for: .path),
                monospaced: true,
                color: .secondary
            )
        }
        .frame(height: 36)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? Color.pink.opacity(0.16) : Color.primary.opacity(0.035))
        }
        .contentShape(Rectangle())
    }
}

private struct ProcessTableActionsCell: View {
    let width: CGFloat
    let onTerminate: () -> Void
    let onForceKill: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onTerminate) {
                Image(systemName: "xmark.circle")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 40, height: 22)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Terminate (SIGTERM)")

            Button(role: .destructive, action: onForceKill) {
                Image(systemName: "bolt.trianglebadge.exclamationmark")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 40, height: 22)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Force Kill (SIGKILL)")
        }
        .frame(width: width, alignment: .center)
        .padding(.horizontal, 8)
    }
}

private struct ProcessTableCell: View {
    let text: String
    let width: CGFloat
    var alignment: Alignment = .leading
    var weight: Font.Weight = .regular
    var monospaced = false
    var color: Color = .primary

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: weight, design: monospaced ? .monospaced : .default))
            .foregroundStyle(color)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(width: width, alignment: alignment)
            .padding(.horizontal, 8)
    }
}

private struct ProcessDetailCard: View {
    let process: ProcessMonitorRow?
    let actionMessage: String
    let onTerminate: (ProcessMonitorRow) -> Void
    let onForceKill: (ProcessMonitorRow) -> Void

    var body: some View {
        GlassCard {
            if let process {
                VStack(alignment: .leading, spacing: 14) {
                    DashboardPanelHeader(
                        title: "Process Detail",
                        subtitle: "\(process.name) · PID \(process.processID)"
                    )

                    VStack(spacing: 10) {
                        ProcessDetailFactRow(label: "User", value: process.userName)
                        ProcessDetailFactRow(label: "CPU", value: process.cpuText)
                        ProcessDetailFactRow(label: "Memory", value: process.memoryText)
                        ProcessDetailFactRow(label: "State", value: process.state)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Executable Path")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        Text(process.executablePathText)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                            .lineLimit(5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color.primary.opacity(0.045))
                            }
                    }

                    HStack(spacing: 10) {
                        Button {
                            onTerminate(process)
                        } label: {
                            Label("Terminate", systemImage: "xmark.circle")
                        }

                        Button(role: .destructive) {
                            onForceKill(process)
                        } label: {
                            Label("Force Kill", systemImage: "bolt.trianglebadge.exclamationmark")
                        }
                    }
                    .buttonStyle(.bordered)

                    if !actionMessage.isEmpty {
                        Text(actionMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 420, alignment: .topLeading)
            } else {
                ContentUnavailableView(
                    "No Process Selected",
                    systemImage: "list.bullet.rectangle.portrait",
                    description: Text("Select a process row to inspect it.")
                )
                .frame(maxWidth: .infinity, minHeight: 420)
            }
        }
    }
}

private struct ProcessDetailFactRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .leading)

            Text(value)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
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

private struct DashboardTrendCard: View {
    let card: DashboardTrendCardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Label(card.title, systemImage: symbolName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(accentColor)

                    Text(card.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 4) {
                    Text(card.currentValueText)
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .monospacedDigit()

                    Text(card.deltaText)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(deltaColor)
                }
            }

            Chart(card.points) { point in
                if usesAreaFill {
                    AreaMark(
                        x: .value("Captured At", point.timestamp),
                        y: .value("Value", point.value)
                    )
                    .foregroundStyle(accentColor.opacity(0.14))
                }

                LineMark(
                    x: .value("Captured At", point.timestamp),
                    y: .value("Value", point.value)
                )
                .foregroundStyle(accentColor)
                .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                .interpolationMethod(.catmullRom)

                if point.id == card.points.last?.id {
                    PointMark(
                        x: .value("Captured At", point.timestamp),
                        y: .value("Value", point.value)
                    )
                    .foregroundStyle(accentColor)
                    .symbolSize(44)
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 4]))
                        .foregroundStyle(Color.secondary.opacity(0.18))
                    AxisTick(stroke: StrokeStyle(lineWidth: 0.5))
                        .foregroundStyle(Color.secondary.opacity(0.28))
                    AxisValueLabel {
                        if let date = value.as(Date.self) {
                            Text(date, format: .dateTime.hour().minute())
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                        .foregroundStyle(Color.secondary.opacity(0.14))
                    AxisValueLabel {
                        if let yValue = value.as(Double.self) {
                            Text(axisLabel(for: yValue))
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            }
            .chartPlotStyle { plot in
                plot
                    .background(Color.primary.opacity(0.03))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .frame(height: 180)

            Text(windowText)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, minHeight: 288, alignment: .topLeading)
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.primary.opacity(0.04))
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(accentColor.opacity(0.14), lineWidth: 1)
                }
        }
    }

    private var accentColor: Color {
        switch card.metric {
        case .cpuUsage:
            return .blue
        case .cpuLoad:
            return .indigo
        case .memoryUsage:
            return .indigo
        case .batteryLevel:
            return .green
        case .systemPower:
            return .orange
        case .downloadRate:
            return .cyan
        case .uploadRate:
            return .pink
        }
    }

    private var deltaColor: Color {
        if card.deltaText.hasPrefix("-") {
            return .secondary
        }
        if card.deltaText == "0 B/s" || card.deltaText == "+0 pts" || card.deltaText == "+0.0 W" {
            return .secondary
        }
        return accentColor
    }

    private var symbolName: String {
        switch card.metric {
        case .cpuUsage:
            return "cpu.fill"
        case .cpuLoad:
            return "waveform.path.ecg"
        case .memoryUsage:
            return "memorychip.fill"
        case .batteryLevel:
            return "battery.100"
        case .systemPower:
            return "bolt.fill"
        case .downloadRate:
            return "arrow.down.circle.fill"
        case .uploadRate:
            return "arrow.up.circle.fill"
        }
    }

    private var usesAreaFill: Bool {
        switch card.metric {
        case .cpuUsage, .memoryUsage, .batteryLevel:
            return true
        case .cpuLoad, .systemPower, .downloadRate, .uploadRate:
            return false
        }
    }

    private var windowText: String {
        guard let first = card.points.first?.timestamp, let last = card.points.last?.timestamp else {
            return "Waiting for recent saved samples."
        }

        return "\(first.formatted(.dateTime.hour().minute())) to \(last.formatted(.dateTime.hour().minute()))"
    }

    private func axisLabel(for value: Double) -> String {
        switch card.metric {
        case .cpuUsage, .memoryUsage, .batteryLevel:
            return String(format: "%.0f%%", value)
        case .cpuLoad:
            return String(format: "%.1f", value)
        case .systemPower:
            return String(format: "%.0fW", value)
        case .downloadRate, .uploadRate:
            return compactRate(value)
        }
    }

    private func compactRate(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond > 0 else { return "0" }

        let units = ["B", "K", "M", "G"]
        var value = bytesPerSecond
        var index = 0
        while value >= 1024, index < units.count - 1 {
            value /= 1024
            index += 1
        }
        return String(format: "%.0f%@", value, units[index])
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
