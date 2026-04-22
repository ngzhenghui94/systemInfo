import Foundation

enum DashboardSection: String, CaseIterable, Identifiable {
    case overview
    case performance
    case power
    case network
    case history

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
        case .history:
            return "History & Report"
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
        case .history:
            return "clock.arrow.trianglehead.counterclockwise.rotate.90"
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
        case .history:
            return ["history", "report", "timeline", "samples", "saved"]
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
        case .history:
            return "Saved monitoring data and the generated Markdown report."
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
        coverageText: String
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
        case .history:
            let noun = sampleCount == 1 ? "sample" : "samples"
            return "\(sampleCount) \(noun) · \(coverageText)"
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
}
