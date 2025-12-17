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
    
    var body: some View {
        VStack(spacing: 16) {
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
            
            // Gauges Section
            GlassCard {
                HStack(spacing: 20) {
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
                        icon: "internaldrive",
                        label: "Disk Free",
                        value: viewModel.freeDiskSpace,
                        iconColor: .orange
                    )
                    
                    StatRow(
                        icon: "bolt.fill",
                        label: "Power Source",
                        value: "\(viewModel.powerSource) • \(viewModel.chargingWattage)",
                        iconColor: .yellow
                    )
                }
            }
            
            // Network Section
            GlassCard {
                NetworkSpeedBar(
                    downloadSpeed: viewModel.downloadSpeed,
                    uploadSpeed: viewModel.uploadSpeed
                )
            }
        }
        .padding(20)
        .frame(width: 360)
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
