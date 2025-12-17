//
//  ContentView.swift
//  systemInfo
//
//  Created by Daniel Ng Zheng Hui on 12/9/25.
//

import SwiftUI
import Combine
import Darwin
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

    private let networkMonitor = NetworkMonitor()
    private var timer: Timer?

    init() {
        updateStaticInfo()
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

    private func updateDynamicInfo() {
        uptime = Self.format(uptimeSeconds: ProcessInfo.processInfo.systemUptime)

        memoryUsage = Self.memoryUsageSummary()
        cpuUsage = Self.cpuUsageSummary()
        loadAverage = Self.loadAverageSummary()

        updatePowerInfo()

        let speeds = networkMonitor.currentSpeeds()
        downloadSpeed = Self.format(bytesPerSecond: speeds.download)
        uploadSpeed = Self.format(bytesPerSecond: speeds.upload)
        
        // New dynamic info
        thermalState = Self.getThermalState()
        ipAddress = Self.getIPAddress()
        wifiNetwork = Self.getWiFiSSID()
        freeMemory = Self.getFreeMemory()
        updateDiskUsage()
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
        chargingWattage = info.watts
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

    private static func batteryInfo() -> (level: String, source: String, watts: String) {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef],
              !list.isEmpty else {
            return ("—", "No battery", "—")
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

            // Charging wattage (approximate)
            var wattsString = "—"
            if let voltage = description[kIOPSVoltageKey as String] as? Double,
               let currentMA = description[kIOPSCurrentKey as String] as? Double {
                // voltage is in mV, current in mA → W = V * A
                let watts = abs(voltage * currentMA) / 1_000_000.0
                if watts > 0.1 {
                    wattsString = String(format: "%.1f W", watts)
                }
            }

            return (levelString, sourceString, wattsString)
        }

        return ("—", "No battery", "—")
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
            .padding(14)
            .background {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .shadow(color: .black.opacity(0.1), radius: 8, x: 0, y: 4)
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
    
    private var cpuValue: Double {
        let cleaned = viewModel.cpuUsage.replacingOccurrences(of: "%", with: "")
        return (Double(cleaned) ?? 0) / 100.0
    }
    
    private var memoryValue: Double {
        // Parse "X.X / Y.Y GB" format
        let parts = viewModel.memoryUsage.components(separatedBy: " / ")
        if parts.count == 2,
           let used = Double(parts[0]),
           let total = Double(parts[1].replacingOccurrences(of: " GB", with: "")) {
            return used / total
        }
        return 0
    }
    
    private var memoryPercent: String {
        let pct = memoryValue * 100
        return String(format: "%.0f%%", pct)
    }
    
    private var batteryValue: Double {
        let cleaned = viewModel.batteryLevel.replacingOccurrences(of: "%", with: "")
        return (Double(cleaned) ?? 0) / 100.0
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
    
    private var diskPercent: String {
        String(format: "%.0f%%", viewModel.diskUsagePercent * 100)
    }
    
    private var thermalColor: Color {
        switch viewModel.thermalState {
        case "Normal": return .green
        case "Fair": return .yellow
        case "Serious": return .orange
        case "Critical": return .red
        default: return .gray
        }
    }
    

    
    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                // Header
                HStack(spacing: 10) {
                    ZStack {
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [.blue, .purple],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 36, height: 36)
                        
                        Image(systemName: "gauge.with.dots.needle.67percent")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text("System Monitor")
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                        
                        HStack(spacing: 4) {
                            Circle()
                                .fill(.green)
                                .frame(width: 6, height: 6)
                            Text("Live • \(viewModel.hostName)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    
                    Spacer()
                    
                    Text(viewModel.macOSVersion)
                        .font(.caption)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background {
                            Capsule()
                                .fill(Color.blue.opacity(0.15))
                        }
                        .foregroundStyle(.blue)
                }
                
                // Main Gauges Section
                GlassCard {
                    HStack(spacing: 16) {
                        CircularGaugeView(
                            value: cpuValue,
                            label: "CPU",
                            valueText: viewModel.cpuUsage,
                            icon: "cpu",
                            gradientColors: [.blue, .cyan]
                        )
                        
                        CircularGaugeView(
                            value: memoryValue,
                            label: "Memory",
                            valueText: memoryPercent,
                            icon: "memorychip",
                            gradientColors: [.purple, .pink]
                        )
                        
                        CircularGaugeView(
                            value: viewModel.diskUsagePercent,
                            label: "Disk",
                            valueText: diskPercent,
                            icon: "internaldrive",
                            gradientColors: [.orange, .yellow]
                        )
                        
                        CircularGaugeView(
                            value: batteryValue,
                            label: "Battery",
                            valueText: viewModel.batteryLevel,
                            icon: "battery.100",
                            gradientColors: batteryGradient
                        )
                    }
                    .frame(maxWidth: .infinity)
                }
                

                // System Details
                GlassCard {
                    VStack(spacing: 4) {
                        HStack {
                            Text("System")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .padding(.bottom, 4)
                        
                        StatRow(
                            icon: "waveform.path.ecg",
                            label: "Load Average",
                            value: viewModel.loadAverage,
                            iconColor: .indigo
                        )
                        
                        StatRow(
                            icon: "clock.arrow.circlepath",
                            label: "Uptime",
                            value: viewModel.uptime,
                            iconColor: .teal
                        )
                        
                        StatRow(
                            icon: "thermometer.medium",
                            label: "Thermal State",
                            value: viewModel.thermalState,
                            iconColor: thermalColor
                        )
                        
                        StatRow(
                            icon: "memorychip",
                            label: "Free Memory",
                            value: viewModel.freeMemory,
                            iconColor: .purple
                        )
                    }
                }
                
                // Storage Section
                GlassCard {
                    VStack(spacing: 4) {
                        HStack {
                            Text("Storage")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .padding(.bottom, 4)
                        
                        StatRow(
                            icon: "internaldrive",
                            label: "Total Space",
                            value: viewModel.totalDiskSpace,
                            iconColor: .orange
                        )
                        
                        StatRow(
                            icon: "internaldrive.fill",
                            label: "Free Space",
                            value: viewModel.freeDiskSpace,
                            iconColor: .green
                        )
                        
                        StatRow(
                            icon: "chart.pie",
                            label: "Used",
                            value: diskPercent,
                            iconColor: .red
                        )
                    }
                }
                
                // Power Section
                GlassCard {
                    VStack(spacing: 4) {
                        HStack {
                            Text("Power")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .padding(.bottom, 4)
                        
                        StatRow(
                            icon: "battery.100",
                            label: "Battery Level",
                            value: viewModel.batteryLevel,
                            iconColor: batteryGradient.first ?? .green
                        )
                        
                        StatRow(
                            icon: "powerplug",
                            label: "Power Source",
                            value: viewModel.powerSource,
                            iconColor: .yellow
                        )
                        
                        StatRow(
                            icon: "bolt.fill",
                            label: "Charge Rate",
                            value: viewModel.chargingWattage,
                            iconColor: .orange
                        )
                    }
                }
                
                // Network Section
                GlassCard {
                    VStack(spacing: 8) {
                        HStack {
                            Text("Network")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        
                        HStack(spacing: 4) {
                            StatRow(
                                icon: "wifi",
                                label: "Wi-Fi",
                                value: viewModel.wifiNetwork,
                                iconColor: .blue
                            )
                        }
                        
                        StatRow(
                            icon: "network",
                            label: "IP Address",
                            value: viewModel.ipAddress,
                            iconColor: .purple
                        )
                        
                        Divider()
                            .padding(.vertical, 4)
                        
                        NetworkSpeedBar(
                            downloadSpeed: viewModel.downloadSpeed,
                            uploadSpeed: viewModel.uploadSpeed
                        )
                    }
                }
            }
            .padding(20)
        }
        .frame(width: 380, height: 600)
        .background {
            // Subtle gradient background
            LinearGradient(
                colors: [
                    Color(nsColor: .windowBackgroundColor),
                    Color(nsColor: .windowBackgroundColor).opacity(0.95)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }
}

#Preview {
    ContentView()
}
