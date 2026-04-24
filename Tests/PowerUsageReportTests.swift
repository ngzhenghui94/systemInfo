import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("Expectation failed: \(message)\n", stderr)
        exit(1)
    }
}

private func expectNear(_ actual: Double?, _ expected: Double, tolerance: Double = 0.001, _ message: String) {
    guard let actual else {
        fputs("Expectation failed: \(message) (value was nil)\n", stderr)
        exit(1)
    }

    if abs(actual - expected) > tolerance {
        fputs("Expectation failed: \(message) (expected \(expected), got \(actual))\n", stderr)
        exit(1)
    }
}

private func makeDate(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
    var components = DateComponents()
    components.calendar = Calendar(identifier: .gregorian)
    components.timeZone = TimeZone(secondsFromGMT: 0)
    components.year = year
    components.month = month
    components.day = day
    components.hour = hour
    components.minute = minute
    return components.date!
}

private func makeSample(
    capturedAt: Date,
    batteryLevelPercent: Double,
    powerUsageWatts: Double?,
    powerSource: String,
    powerMetricKind: PowerMetricKind? = .systemPower,
    powerMetricSource: String? = "AppleSmartBattery/BatteryData.SystemPower"
) -> SystemHistorySample {
    SystemHistorySample(
        capturedAt: capturedAt,
        hostName: "Studio-Mac",
        macOSVersion: "macOS 26.0",
        cpuModel: "M4 Pro",
        cpuCores: "12 cores",
        gpuName: "Apple GPU",
        cpuUsageText: "28%",
        cpuUsagePercent: 28,
        loadAverageText: "1.12, 1.08",
        loadAverageOneMinute: 1.12,
        loadAverageFiveMinute: 1.08,
        memoryUsageText: "9.5 / 18.0 GB",
        memoryUsedGB: 9.5,
        memoryTotalGB: 18.0,
        batteryLevelText: "\(Int(batteryLevelPercent))%",
        batteryLevelPercent: batteryLevelPercent,
        powerSource: powerSource,
        powerUsageText: powerUsageWatts.map { String(format: "%.1f W", $0) } ?? "—",
        powerUsageWatts: powerUsageWatts,
        powerMetricKind: powerMetricKind,
        powerMetricSource: powerMetricSource,
        chargingWattageText: "—",
        uptimeText: "3h 02m",
        uptimeSeconds: 10_920,
        freeDiskSpaceText: "278.0 GB",
        freeDiskBytes: 278 * 1_024 * 1_024 * 1_024,
        totalDiskSpaceText: "512.0 GB",
        totalDiskBytes: 512 * 1_024 * 1_024 * 1_024,
        diskUsagePercent: 0.457,
        downloadSpeedText: "1.2 MB/s",
        downloadBytesPerSecond: 1.2 * 1_024 * 1_024,
        uploadSpeedText: "210.0 KB/s",
        uploadBytesPerSecond: 210 * 1_024,
        thermalState: "Normal",
        ipAddress: "192.168.1.20",
        wifiNetwork: "OfficeNet",
        freeMemoryText: "8.5 / 18.0 GB"
    )
}

@main
struct PowerUsageReportTests {
    static func main() throws {
        try testReportBuilderSummarizesScopedPowerHistory()
        try testMarkdownArtifactIncludesTrendAndPeakMoments()
        try testStorePersistsDedicatedPowerReportArtifact()
        print("Power usage report tests passed")
    }

    private static func testReportBuilderSummarizesScopedPowerHistory() throws {
        let samples = [
            makeSample(capturedAt: makeDate(2026, 4, 22, 0, 0), batteryLevelPercent: 92, powerUsageWatts: 8, powerSource: "Battery"),
            makeSample(capturedAt: makeDate(2026, 4, 22, 0, 30), batteryLevelPercent: 87, powerUsageWatts: 11, powerSource: "Battery"),
            makeSample(capturedAt: makeDate(2026, 4, 22, 1, 0), batteryLevelPercent: 84, powerUsageWatts: 16, powerSource: "AC Power"),
            makeSample(capturedAt: makeDate(2026, 4, 22, 1, 30), batteryLevelPercent: 83, powerUsageWatts: 18, powerSource: "AC Power"),
            makeSample(capturedAt: makeDate(2026, 4, 22, 2, 0), batteryLevelPercent: 82, powerUsageWatts: 20, powerSource: "AC Power", powerMetricKind: nil, powerMetricSource: nil)
        ]

        let report = PowerUsageReportBuilder.build(from: samples)

        expect(report.sampleCount == 5, "sample count mismatch")
        expect(report.powerSampleCount == 4, "only scoped power samples should contribute to the report")
        expect(report.coverageText == "1h 30m", "coverage should span the scoped report range")
        expectNear(report.averageWatts, 13.25, "average watts mismatch")
        expectNear(report.maximumWatts, 18.0, "peak watts mismatch")
        expectNear(report.latestWatts, 18.0, "latest watts should come from the latest scoped sample")
        expect(report.trendDirection == .rising, "trend direction should detect a rising load")
        expectNear(report.trendDeltaWatts, 7.5, "trend delta mismatch")
        expectNear(report.batteryDeltaPercent, -9.0, "battery delta mismatch")
        expect(report.excludedPowerSampleCount == 1, "unscoped power samples should be counted as excluded")
        expect(report.peakMoments.map(\.watts) == [18.0, 16.0, 11.0], "peak moments should be sorted descending")
        expect(report.powerSourceBreakdown.map(\.label) == ["AC Power", "Battery"], "power source breakdown should be grouped alphabetically")
    }

    private static func testMarkdownArtifactIncludesTrendAndPeakMoments() throws {
        let samples = [
            makeSample(capturedAt: makeDate(2026, 4, 22, 9, 0), batteryLevelPercent: 74, powerUsageWatts: 9, powerSource: "Battery"),
            makeSample(capturedAt: makeDate(2026, 4, 22, 10, 0), batteryLevelPercent: 71, powerUsageWatts: 13, powerSource: "Battery"),
            makeSample(capturedAt: makeDate(2026, 4, 22, 11, 0), batteryLevelPercent: 68, powerUsageWatts: 17, powerSource: "AC Power")
        ]

        let markdown = PowerUsageReportGenerator.generate(from: samples, generatedAt: makeDate(2026, 4, 22, 12, 0))

        expect(markdown.contains("# Power Usage Report"), "artifact header missing")
        expect(markdown.contains("System-power samples: 3"), "scoped power sample count missing")
        expect(markdown.contains("Recent trend: Rising (+"), "trend summary should be rendered")
        expect(markdown.contains("| Timestamp | System Power | Battery | Source |"), "peak moments table missing")
        expect(markdown.contains("Excluded legacy or unscoped power samples: 0"), "excluded sample count missing")
    }

    private static func testStorePersistsDedicatedPowerReportArtifact() throws {
        let fileManager = FileManager.default
        let tempDirectory = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = SystemHistoryStore(baseDirectoryURL: tempDirectory, retentionLimit: 10)
        let samples = [
            makeSample(capturedAt: makeDate(2026, 4, 22, 9, 0), batteryLevelPercent: 74, powerUsageWatts: 9, powerSource: "Battery"),
            makeSample(capturedAt: makeDate(2026, 4, 22, 10, 0), batteryLevelPercent: 71, powerUsageWatts: 13, powerSource: "Battery"),
            makeSample(capturedAt: makeDate(2026, 4, 22, 11, 0), batteryLevelPercent: 68, powerUsageWatts: 17, powerSource: "AC Power")
        ]

        let report = try store.refreshPowerReport(using: samples, generatedAt: makeDate(2026, 4, 22, 12, 0))

        let loadedReport = try store.loadPowerReport()

        expect(fileManager.fileExists(atPath: store.powerReportURL.path), "power report artifact should be written to disk")
        expect(loadedReport == report, "stored power report should round-trip")
        expect(store.powerReportURL.lastPathComponent == "latest-power-usage-report.md", "power report file name mismatch")
    }
}
