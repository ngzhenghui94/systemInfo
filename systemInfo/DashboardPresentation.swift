import Foundation

enum DashboardSection: String, CaseIterable, Identifiable {
    case overview
    case performance
    case power
    case network
    case processes
    case history
    case trends

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview:
            return "Overview"
        case .performance:
            return "Performance"
        case .power:
            return "Power"
        case .network:
            return "Network"
        case .processes:
            return "Processes"
        case .history:
            return "History & Report"
        case .trends:
            return "Trends"
        }
    }

    var symbolName: String {
        switch self {
        case .overview:
            return "square.grid.2x2.fill"
        case .performance:
            return "cpu.fill"
        case .power:
            return "bolt.fill"
        case .network:
            return "network"
        case .processes:
            return "list.bullet.rectangle.portrait.fill"
        case .history:
            return "clock.arrow.trianglehead.counterclockwise.rotate.90"
        case .trends:
            return "chart.line.uptrend.xyaxis"
        }
    }

    var keywords: [String] {
        switch self {
        case .overview:
            return ["summary", "dashboard", "system", "status"]
        case .performance:
            return ["cpu", "memory", "disk", "thermal", "load"]
        case .power:
            return ["battery", "charge", "watt", "usage", "power"]
        case .network:
            return ["wifi", "download", "upload", "ip", "throughput"]
        case .processes:
            return ["process", "pid", "memory", "cpu", "path", "terminate", "kill", "root", "system"]
        case .history:
            return ["history", "report", "timeline", "samples", "saved"]
        case .trends:
            return ["power", "report", "history", "trend", "export", "watt", "memory", "cpu", "load", "network", "bandwidth"]
        }
    }

    var blurb: String {
        switch self {
        case .overview:
            return "Live health, key gauges, and the machine identity."
        case .performance:
            return "CPU, memory, disk, and thermal signals together."
        case .power:
            return "Battery state, system power, and charging behavior."
        case .network:
            return "Connection details and real-time throughput."
        case .processes:
            return "Live process table with resource use, executable paths, and local control actions."
        case .history:
            return "Saved monitoring data and the generated Markdown report."
        case .trends:
            return "Trend summaries and charts based on the stored monitoring history."
        }
    }
}

enum DashboardTone: String {
    case nominal
    case elevated
    case critical
}

struct DashboardHealthSummary {
    let tone: DashboardTone
    let title: String
    let subtitle: String
    let highlights: [String]
}

enum DashboardTrendMetric: String, CaseIterable, Identifiable {
    case cpuUsage
    case cpuLoad
    case memoryUsage
    case batteryLevel
    case systemPower
    case downloadRate
    case uploadRate

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cpuUsage:
            return "CPU Usage"
        case .cpuLoad:
            return "CPU Load"
        case .memoryUsage:
            return "Memory Usage"
        case .batteryLevel:
            return "Battery Level"
        case .systemPower:
            return "System Power"
        case .downloadRate:
            return "Download"
        case .uploadRate:
            return "Upload"
        }
    }

    var subtitle: String {
        switch self {
        case .cpuUsage:
            return "Processor activity across the visible history window."
        case .cpuLoad:
            return "One-minute load average captured with each saved sample."
        case .memoryUsage:
            return "Used memory as a share of installed RAM."
        case .batteryLevel:
            return "Battery reserve over the recent capture window."
        case .systemPower:
            return "Whole-system watt draw from Apple battery telemetry."
        case .downloadRate:
            return "Inbound throughput for the recent captured samples."
        case .uploadRate:
            return "Outbound throughput for the recent captured samples."
        }
    }
}

struct DashboardTrendPoint: Equatable, Identifiable {
    let timestamp: Date
    let value: Double

    var id: Date { timestamp }
}

struct DashboardTrendCardModel: Equatable, Identifiable {
    let metric: DashboardTrendMetric
    let title: String
    let subtitle: String
    let currentValueText: String
    let deltaText: String
    let points: [DashboardTrendPoint]

    var id: DashboardTrendMetric { metric }
}

enum DashboardPresentationBuilder {
    static func filteredSections(matching query: String) -> [DashboardSection] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            return DashboardSection.allCases
        }

        let normalizedQuery = trimmedQuery.lowercased()
        return DashboardSection.allCases.filter { section in
            section.title.lowercased().contains(normalizedQuery)
                || section.blurb.lowercased().contains(normalizedQuery)
                || section.keywords.contains(where: { $0.contains(normalizedQuery) })
        }
    }

    static func historySubtitle(sampleCount: Int, coverageText: String) -> String {
        let noun = sampleCount == 1 ? "sample" : "samples"
        return "\(sampleCount) \(noun) captured over \(coverageText)"
    }

    static func compactSectionSummary(
        for section: DashboardSection,
        healthSummary: DashboardHealthSummary,
        cpuUsageText: String,
        memoryPercentText: String,
        powerUsageText: String,
        powerSource: String,
        downloadSpeedText: String,
        uploadSpeedText: String,
        sampleCount: Int,
        coverageText: String,
        processCount: Int = 0,
        processStatusText: String = "Live table"
    ) -> String {
        switch section {
        case .overview:
            switch healthSummary.tone {
            case .nominal:
                return "Stable"
            case .elevated:
                return "Attention needed"
            case .critical:
                return "Under pressure"
            }
        case .performance:
            return "CPU \(cpuUsageText) · MEM \(memoryPercentText)"
        case .power:
            let compactPowerSource = powerSource
                .replacingOccurrences(of: " Power", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if powerUsageText == "—" {
                return compactPowerSource.isEmpty ? "Power unavailable" : compactPowerSource
            }
            return "\(powerUsageText) · \(compactPowerSource)"
        case .network:
            return "\(compactRate(downloadSpeedText))↓ · \(compactRate(uploadSpeedText))↑"
        case .processes:
            return processCount > 0 ? "\(processCount) processes · \(processStatusText)" : processStatusText
        case .history:
            let noun = sampleCount == 1 ? "sample" : "samples"
            return "\(sampleCount) \(noun) · \(coverageText)"
        case .trends:
            return "Charts and deltas for recent samples"
        }
    }

    static func columnCount(for availableWidth: Double, minimumCardWidth: Double, maxColumns: Int) -> Int {
        guard availableWidth > 0, minimumCardWidth > 0, maxColumns > 0 else {
            return 1
        }

        let cardWithSpacing = minimumCardWidth + 16
        let rawCount = Int((availableWidth + 16) / cardWithSpacing)
        return max(1, min(maxColumns, rawCount))
    }

    static func healthSummary(
        cpuUsagePercent: Double?,
        batteryLevelPercent: Double?,
        thermalState: String,
        powerUsageWatts: Double?
    ) -> DashboardHealthSummary {
        let normalizedThermalState = thermalState.lowercased()

        let tone: DashboardTone
        if normalizedThermalState == "critical"
            || normalizedThermalState == "serious"
            || (cpuUsagePercent ?? 0) >= 90 {
            tone = .critical
        } else if normalizedThermalState == "fair"
            || (cpuUsagePercent ?? 0) >= 70
            || ((batteryLevelPercent ?? 100) <= 25) {
            tone = .elevated
        } else {
            tone = .nominal
        }

        let title: String
        let subtitle: String
        switch tone {
        case .nominal:
            title = "System running smoothly"
            subtitle = "Live metrics are in a comfortable range."
        case .elevated:
            title = "System needs attention"
            subtitle = "One or more signals are trending away from nominal."
        case .critical:
            title = "System under pressure"
            subtitle = "The machine is reporting sustained stress or constrained power."
        }

        var highlights: [String] = []
        if let cpuUsagePercent {
            highlights.append("CPU \(Int(cpuUsagePercent.rounded()))%")
        }
        if let batteryLevelPercent {
            highlights.append("Battery \(Int(batteryLevelPercent.rounded()))%")
        }
        if let powerUsageWatts {
            highlights.append(String(format: "System Power %.1f W", powerUsageWatts))
        }
        if !thermalState.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, thermalState != "—" {
            highlights.append("Thermal \(thermalState)")
        }

        return DashboardHealthSummary(
            tone: tone,
            title: title,
            subtitle: subtitle,
            highlights: highlights
        )
    }

    static func recentSamples(_ samples: [SystemHistorySample], limit: Int = 60) -> [SystemHistorySample] {
        guard limit > 0 else {
            return []
        }
        return Array(samples.suffix(limit))
    }

    static func trendWindowSubtitle(totalSampleCount: Int, displayedSampleCount: Int) -> String {
        guard totalSampleCount > 0, displayedSampleCount > 0 else {
            return "Charts will appear after enough saved samples accumulate."
        }

        if displayedSampleCount >= totalSampleCount {
            return "Showing all \(totalSampleCount) saved samples."
        }

        return "Showing the latest \(displayedSampleCount) of \(totalSampleCount) saved samples."
    }

    static func trendCards(from samples: [SystemHistorySample], limit: Int = 60) -> [DashboardTrendCardModel] {
        filteredTrendCards(
            from: samples,
            metrics: Set(DashboardTrendMetric.allCases),
            limit: limit
        )
    }

    static func powerTrendCards(from samples: [SystemHistorySample], limit: Int = 60) -> [DashboardTrendCardModel] {
        filteredTrendCards(
            from: samples,
            metrics: [.batteryLevel, .systemPower],
            limit: limit
        )
    }

    static func resourceTrendCards(from samples: [SystemHistorySample], limit: Int = 60) -> [DashboardTrendCardModel] {
        filteredTrendCards(
            from: samples,
            metrics: [.cpuUsage, .cpuLoad, .memoryUsage, .downloadRate, .uploadRate],
            limit: limit
        )
    }

    private static func filteredTrendCards(
        from samples: [SystemHistorySample],
        metrics: Set<DashboardTrendMetric>,
        limit: Int
    ) -> [DashboardTrendCardModel] {
        let displayedSamples = recentSamples(samples, limit: limit)

        return DashboardTrendMetric.allCases.compactMap { metric in
            guard metrics.contains(metric) else {
                return nil
            }

            let points = displayedSamples.compactMap { sample -> DashboardTrendPoint? in
                guard let value = trendValue(for: metric, from: sample) else {
                    return nil
                }

                return DashboardTrendPoint(timestamp: sample.capturedAt, value: value)
            }

            guard points.count >= 2,
                  let firstValue = points.first?.value,
                  let latestValue = points.last?.value else {
                return nil
            }

            return DashboardTrendCardModel(
                metric: metric,
                title: metric.title,
                subtitle: metric.subtitle,
                currentValueText: formatTrendValue(latestValue, metric: metric),
                deltaText: formatTrendDelta(latest: latestValue, baseline: firstValue, metric: metric),
                points: points
            )
        }
    }

    private static func compactRate(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch true {
        case trimmed.hasSuffix("GB/s"):
            return trimmed.replacingOccurrences(of: " GB/s", with: "G")
        case trimmed.hasSuffix("MB/s"):
            return trimmed.replacingOccurrences(of: " MB/s", with: "M")
        case trimmed.hasSuffix("KB/s"):
            return trimmed.replacingOccurrences(of: " KB/s", with: "K")
        case trimmed.hasSuffix("B/s"):
            return trimmed.replacingOccurrences(of: " B/s", with: "B")
        default:
            return trimmed
        }
    }

    private static func trendValue(for metric: DashboardTrendMetric, from sample: SystemHistorySample) -> Double? {
        switch metric {
        case .cpuUsage:
            return sample.cpuUsagePercent
        case .cpuLoad:
            return sample.loadAverageOneMinute
        case .memoryUsage:
            guard let used = sample.memoryUsedGB, let total = sample.memoryTotalGB, total > 0 else {
                return nil
            }
            return (used / total) * 100
        case .batteryLevel:
            return sample.batteryLevelPercent
        case .systemPower:
            guard sample.powerMetricKind == .systemPower else {
                return nil
            }
            return sample.powerUsageWatts
        case .downloadRate:
            return sample.downloadBytesPerSecond
        case .uploadRate:
            return sample.uploadBytesPerSecond
        }
    }

    private static func formatTrendValue(_ value: Double, metric: DashboardTrendMetric) -> String {
        switch metric {
        case .cpuUsage, .memoryUsage, .batteryLevel:
            return String(format: "%.0f%%", value)
        case .cpuLoad:
            return String(format: "%.2f", value)
        case .systemPower:
            return String(format: "%.1f W", value)
        case .downloadRate, .uploadRate:
            return formatRate(value)
        }
    }

    private static func formatTrendDelta(latest: Double, baseline: Double, metric: DashboardTrendMetric) -> String {
        let delta = latest - baseline
        switch metric {
        case .cpuUsage, .memoryUsage, .batteryLevel:
            return String(format: "%+.0f pts", delta)
        case .cpuLoad:
            return String(format: "%+.2f", delta)
        case .systemPower:
            return String(format: "%+.1f W", delta)
        case .downloadRate, .uploadRate:
            return formatSignedRate(delta)
        }
    }

    private static func formatRate(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond > 0 else { return "0 B/s" }
        let units = ["B/s", "KB/s", "MB/s", "GB/s"]
        var value = bytesPerSecond
        var index = 0
        while value >= 1024, index < units.count - 1 {
            value /= 1024
            index += 1
        }
        return String(format: "%.1f %@", value, units[index])
    }

    private static func formatSignedRate(_ bytesPerSecond: Double) -> String {
        if bytesPerSecond == 0 {
            return "0 B/s"
        }

        let sign = bytesPerSecond >= 0 ? "+" : "-"
        return sign + formatRate(abs(bytesPerSecond))
    }
}
