import Foundation

struct SystemHistorySample: Codable, Equatable {
    let capturedAt: Date
    let hostName: String
    let macOSVersion: String
    let cpuModel: String
    let cpuCores: String
    let gpuName: String
    let cpuUsageText: String
    let cpuUsagePercent: Double?
    let loadAverageText: String
    let loadAverageOneMinute: Double?
    let loadAverageFiveMinute: Double?
    let memoryUsageText: String
    let memoryUsedGB: Double?
    let memoryTotalGB: Double?
    let batteryLevelText: String
    let batteryLevelPercent: Double?
    let powerSource: String
    let powerUsageText: String
    let powerUsageWatts: Double?
    let chargingWattageText: String
    let uptimeText: String
    let uptimeSeconds: TimeInterval?
    let freeDiskSpaceText: String
    let freeDiskBytes: Int64?
    let totalDiskSpaceText: String
    let totalDiskBytes: Int64?
    let diskUsagePercent: Double?
    let downloadSpeedText: String
    let downloadBytesPerSecond: Double?
    let uploadSpeedText: String
    let uploadBytesPerSecond: Double?
    let thermalState: String
    let ipAddress: String
    let wifiNetwork: String
    let freeMemoryText: String
}

struct SystemHistoryOverview {
    let sampleCount: Int
    let firstCapturedAt: Date?
    let lastCapturedAt: Date?

    var coverageText: String {
        guard let firstCapturedAt, let lastCapturedAt else {
            return "0m"
        }
        return SystemHistoryOverview.format(duration: lastCapturedAt.timeIntervalSince(firstCapturedAt))
    }

    private static func format(duration: TimeInterval) -> String {
        let totalMinutes = max(Int(duration.rounded()) / 60, 0)
        let days = totalMinutes / 1_440
        let hours = (totalMinutes % 1_440) / 60
        let minutes = totalMinutes % 60

        var parts: [String] = []
        if days > 0 {
            parts.append("\(days)d")
        }
        if hours > 0 || !parts.isEmpty {
            parts.append("\(hours)h")
        }
        parts.append("\(minutes)m")
        return parts.joined(separator: " ")
    }
}

final class SystemHistoryStore {
    let baseDirectoryURL: URL
    let historyURL: URL
    let reportURL: URL

    private let fileManager: FileManager
    private let retentionLimit: Int
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(
        baseDirectoryURL: URL? = nil,
        retentionLimit: Int = 10_080,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        self.retentionLimit = max(retentionLimit, 1)

        let resolvedBaseDirectoryURL = baseDirectoryURL ?? Self.defaultBaseDirectoryURL(fileManager: fileManager)
        self.baseDirectoryURL = resolvedBaseDirectoryURL
        self.historyURL = resolvedBaseDirectoryURL.appendingPathComponent("system-stats-history.json")
        self.reportURL = resolvedBaseDirectoryURL.appendingPathComponent("latest-system-report.md")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    func loadSamples() throws -> [SystemHistorySample] {
        guard fileManager.fileExists(atPath: historyURL.path) else {
            return []
        }

        let data = try Data(contentsOf: historyURL)
        return try decoder.decode([SystemHistorySample].self, from: data)
    }

    @discardableResult
    func record(
        _ sample: SystemHistorySample,
        shouldGenerateReport: Bool = false,
        generatedAt: Date? = nil
    ) throws -> [SystemHistorySample] {
        var samples = try loadSamples()
        samples.append(sample)

        if samples.count > retentionLimit {
            samples.removeFirst(samples.count - retentionLimit)
        }

        try ensureBaseDirectoryExists()
        try save(samples)

        if shouldGenerateReport {
            let report = SystemReportGenerator.generate(from: samples, generatedAt: generatedAt ?? sample.capturedAt)
            try saveReport(report)
        }

        return samples
    }

    @discardableResult
    func refreshReport(using samples: [SystemHistorySample], generatedAt: Date = Date()) throws -> String {
        let report = SystemReportGenerator.generate(from: samples, generatedAt: generatedAt)
        try saveReport(report)
        return report
    }

    func loadReport() throws -> String? {
        guard fileManager.fileExists(atPath: reportURL.path) else {
            return nil
        }
        return try String(contentsOf: reportURL, encoding: .utf8)
    }

    func overview(for samples: [SystemHistorySample]) -> SystemHistoryOverview {
        SystemHistoryOverview(
            sampleCount: samples.count,
            firstCapturedAt: samples.first?.capturedAt,
            lastCapturedAt: samples.last?.capturedAt
        )
    }

    private func save(_ samples: [SystemHistorySample]) throws {
        let data = try encoder.encode(samples)
        try data.write(to: historyURL, options: .atomic)
    }

    private func saveReport(_ report: String) throws {
        try ensureBaseDirectoryExists()
        try report.write(to: reportURL, atomically: true, encoding: .utf8)
    }

    private func ensureBaseDirectoryExists() throws {
        try fileManager.createDirectory(at: baseDirectoryURL, withIntermediateDirectories: true)
    }

    private static func defaultBaseDirectoryURL(fileManager: FileManager) -> URL {
        let appSupportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return appSupportURL.appendingPathComponent("systemInfo", isDirectory: true)
    }
}

enum SystemReportGenerator {
    static func generate(from samples: [SystemHistorySample], generatedAt: Date = Date()) -> String {
        guard !samples.isEmpty else {
            return """
            # System Monitoring Report

            Generated: \(format(date: generatedAt))
            Samples stored: 0

            No historical samples have been captured yet.
            """
        }

        let sortedSamples = samples.sorted { $0.capturedAt < $1.capturedAt }
        let latestSample = sortedSamples[sortedSamples.count - 1]
        let overview = SystemHistoryOverview(
            sampleCount: sortedSamples.count,
            firstCapturedAt: sortedSamples.first?.capturedAt,
            lastCapturedAt: sortedSamples.last?.capturedAt
        )

        var lines: [String] = [
            "# System Monitoring Report",
            "",
            "Generated: \(format(date: generatedAt))",
            "Samples stored: \(sortedSamples.count)",
            "Range: \(format(date: sortedSamples[0].capturedAt)) -> \(format(date: latestSample.capturedAt))",
            "Coverage: \(overview.coverageText)",
            "",
            "## Current Snapshot",
            "- Host: \(latestSample.hostName)",
            "- macOS: \(latestSample.macOSVersion)",
            "- CPU: \(latestSample.cpuModel) (\(latestSample.cpuCores))",
            "- GPU: \(latestSample.gpuName)",
            "- Uptime: \(latestSample.uptimeText)",
            "- Thermal state: \(latestSample.thermalState)",
            "- Power source: \(latestSample.powerSource)",
            "- Power usage: \(latestSample.powerUsageText)",
            "- Battery level: \(latestSample.batteryLevelText)",
            "- Free memory: \(latestSample.freeMemoryText)",
            "- Disk free: \(latestSample.freeDiskSpaceText) of \(latestSample.totalDiskSpaceText)",
            "- Wi-Fi: \(latestSample.wifiNetwork)",
            "- IP address: \(latestSample.ipAddress)",
            "",
            "## Resource Trends"
        ]

        if let summary = summarize(sortedSamples.compactMap(\.cpuUsagePercent)) {
            lines.append("- CPU usage: \(formatPercentageSummary(summary))")
        }
        if let summary = summarize(memoryPercents(from: sortedSamples)) {
            lines.append("- Memory usage: \(formatPercentageSummary(summary))")
        }
        if let summary = summarize(sortedSamples.compactMap(\.diskUsagePercent).map { $0 * 100 }) {
            lines.append("- Disk usage: \(formatPercentageSummary(summary))")
        }
        if let summary = summarize(sortedSamples.compactMap(\.batteryLevelPercent)) {
            lines.append("- Battery level: \(formatPercentageSummary(summary))")
        }
        if let summary = summarize(sortedSamples.compactMap(\.powerUsageWatts)) {
            lines.append("- Power usage: \(formatWattSummary(summary))")
        }
        if let summary = summarize(sortedSamples.compactMap(\.downloadBytesPerSecond)) {
            lines.append("- Download throughput: \(formatTransferSummary(summary))")
        }
        if let summary = summarize(sortedSamples.compactMap(\.uploadBytesPerSecond)) {
            lines.append("- Upload throughput: \(formatTransferSummary(summary))")
        }

        lines.append("")
        lines.append("## Environment Observations")
        lines.append("- Thermal states observed: \(summarizeCounts(sortedSamples.map(\.thermalState)))")
        lines.append("- Power sources observed: \(summarizeCounts(sortedSamples.map(\.powerSource)))")
        lines.append("- Wi-Fi networks observed: \(summarizeCounts(sortedSamples.map(\.wifiNetwork)))")

        return lines.joined(separator: "\n")
    }

    private struct NumericSummary {
        let average: Double
        let minimum: Double
        let maximum: Double
        let latest: Double
    }

    private static func memoryPercents(from samples: [SystemHistorySample]) -> [Double] {
        samples.compactMap { sample in
            guard let used = sample.memoryUsedGB, let total = sample.memoryTotalGB, total > 0 else {
                return nil
            }
            return (used / total) * 100
        }
    }

    private static func summarize(_ values: [Double]) -> NumericSummary? {
        guard let firstValue = values.first else {
            return nil
        }

        var total = 0.0
        var minimum = firstValue
        var maximum = firstValue

        for value in values {
            total += value
            minimum = min(minimum, value)
            maximum = max(maximum, value)
        }

        return NumericSummary(
            average: total / Double(values.count),
            minimum: minimum,
            maximum: maximum,
            latest: values[values.count - 1]
        )
    }

    private static func summarizeCounts(_ values: [String]) -> String {
        let filteredValues = values
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0 != "—" }

        guard !filteredValues.isEmpty else {
            return "No observations"
        }

        let counts = filteredValues.reduce(into: [String: Int]()) { partialResult, value in
            partialResult[value, default: 0] += 1
        }

        return counts
            .sorted { lhs, rhs in
                if lhs.key == rhs.key {
                    return lhs.value < rhs.value
                }
                return lhs.key < rhs.key
            }
            .map { "\($0.key) (\($0.value))" }
            .joined(separator: ", ")
    }

    private static func formatPercentageSummary(_ summary: NumericSummary) -> String {
        String(
            format: "avg %.1f%%, min %.1f%%, max %.1f%%, latest %.1f%%",
            summary.average,
            summary.minimum,
            summary.maximum,
            summary.latest
        )
    }

    private static func formatWattSummary(_ summary: NumericSummary) -> String {
        String(
            format: "avg %.1f W, min %.1f W, max %.1f W, latest %.1f W",
            summary.average,
            summary.minimum,
            summary.maximum,
            summary.latest
        )
    }

    private static func formatTransferSummary(_ summary: NumericSummary) -> String {
        "avg \(format(bytesPerSecond: summary.average)), max \(format(bytesPerSecond: summary.maximum)), latest \(format(bytesPerSecond: summary.latest))"
    }

    private static func format(bytesPerSecond: Double) -> String {
        guard bytesPerSecond > 0 else {
            return "0 B/s"
        }

        let units = ["B/s", "KB/s", "MB/s", "GB/s"]
        var value = bytesPerSecond
        var index = 0

        while value >= 1024 && index < units.count - 1 {
            value /= 1024
            index += 1
        }

        return String(format: "%.1f %@", value, units[index])
    }

    private static func format(date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}
