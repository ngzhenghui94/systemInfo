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
    let powerMetricKind: PowerMetricKind?
    let powerMetricSource: String?
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
    let powerReportURL: URL

    var reportURL: URL { powerReportURL }

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
        self.powerReportURL = resolvedBaseDirectoryURL.appendingPathComponent("latest-power-usage-report.md")

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
            let report = PowerUsageReportGenerator.generate(from: samples, generatedAt: generatedAt ?? sample.capturedAt)
            try savePowerReport(report)
        }

        return samples
    }

    @discardableResult
    func refreshPowerReport(using samples: [SystemHistorySample], generatedAt: Date = Date()) throws -> String {
        let report = PowerUsageReportGenerator.generate(from: samples, generatedAt: generatedAt)
        try savePowerReport(report)
        return report
    }

    @discardableResult
    func refreshReport(using samples: [SystemHistorySample], generatedAt: Date = Date()) throws -> String {
        try refreshPowerReport(using: samples, generatedAt: generatedAt)
    }

    func loadPowerReport() throws -> String? {
        guard fileManager.fileExists(atPath: powerReportURL.path) else {
            return nil
        }
        return try String(contentsOf: powerReportURL, encoding: .utf8)
    }

    func loadReport() throws -> String? {
        try loadPowerReport()
    }

    func overview(for samples: [SystemHistorySample]) -> SystemHistoryOverview {
        SystemHistoryOverview(
            sampleCount: samples.count,
            firstCapturedAt: samples.first?.capturedAt,
            lastCapturedAt: samples.last?.capturedAt
        )
    }

    /// Deletes all persisted history and the cached power report from disk.
    func clearHistory() throws {
        for url in [historyURL, powerReportURL] {
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
        }
    }

    private func save(_ samples: [SystemHistorySample]) throws {
        let data = try encoder.encode(samples)
        try data.write(to: historyURL, options: .atomic)
    }

    private func savePowerReport(_ report: String) throws {
        try ensureBaseDirectoryExists()
        try report.write(to: powerReportURL, atomically: true, encoding: .utf8)
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
        PowerUsageReportGenerator.generate(from: samples, generatedAt: generatedAt)
    }
}
