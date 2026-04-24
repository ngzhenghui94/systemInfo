import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("Expectation failed: \(message)\n", stderr)
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
    cpuUsagePercent: Double,
    memoryUsedGB: Double,
    memoryTotalGB: Double,
    batteryLevelPercent: Double,
    powerUsageWatts: Double,
    freeDiskBytes: Int64,
    totalDiskBytes: Int64,
    downloadBytesPerSecond: Double,
    uploadBytesPerSecond: Double,
    thermalState: String = "Normal",
    powerSource: String = "Battery",
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
        cpuUsageText: "\(Int(cpuUsagePercent))%",
        cpuUsagePercent: cpuUsagePercent,
        loadAverageText: "1.00, 0.90",
        loadAverageOneMinute: 1.0,
        loadAverageFiveMinute: 0.9,
        memoryUsageText: String(format: "%.1f / %.1f GB", memoryUsedGB, memoryTotalGB),
        memoryUsedGB: memoryUsedGB,
        memoryTotalGB: memoryTotalGB,
        batteryLevelText: "\(Int(batteryLevelPercent))%",
        batteryLevelPercent: batteryLevelPercent,
        powerSource: powerSource,
        powerUsageText: String(format: "%.1f W", powerUsageWatts),
        powerUsageWatts: powerUsageWatts,
        powerMetricKind: powerMetricKind,
        powerMetricSource: powerMetricSource,
        chargingWattageText: "—",
        uptimeText: "2h 15m",
        uptimeSeconds: 8_100,
        freeDiskSpaceText: "300.0 GB",
        freeDiskBytes: freeDiskBytes,
        totalDiskSpaceText: "512.0 GB",
        totalDiskBytes: totalDiskBytes,
        diskUsagePercent: 1 - (Double(freeDiskBytes) / Double(totalDiskBytes)),
        downloadSpeedText: "1.0 MB/s",
        downloadBytesPerSecond: downloadBytesPerSecond,
        uploadSpeedText: "250.0 KB/s",
        uploadBytesPerSecond: uploadBytesPerSecond,
        thermalState: thermalState,
        ipAddress: "192.168.1.20",
        wifiNetwork: "OfficeNet",
        freeMemoryText: "10.0 / 18.0 GB"
    )
}

@main
struct MonitoringHistoryTests {
    static func main() throws {
        try testReportSummarizesPowerUsageAndCoverage()
        try testReportExcludesLegacyUnscopedPowerSamples()
        try testStorePrunesToRetentionLimit()
        print("Monitoring history tests passed")
    }

    private static func testReportSummarizesPowerUsageAndCoverage() throws {
        let samples = [
            makeSample(
                capturedAt: makeDate(2026, 4, 22, 0, 0),
                cpuUsagePercent: 10,
                memoryUsedGB: 8,
                memoryTotalGB: 16,
                batteryLevelPercent: 90,
                powerUsageWatts: 8,
                freeDiskBytes: 300 * 1_024 * 1_024 * 1_024,
                totalDiskBytes: 512 * 1_024 * 1_024 * 1_024,
                downloadBytesPerSecond: 1_024 * 1_024,
                uploadBytesPerSecond: 256 * 1_024
            ),
            makeSample(
                capturedAt: makeDate(2026, 4, 22, 1, 0),
                cpuUsagePercent: 40,
                memoryUsedGB: 10,
                memoryTotalGB: 16,
                batteryLevelPercent: 75,
                powerUsageWatts: 14,
                freeDiskBytes: 290 * 1_024 * 1_024 * 1_024,
                totalDiskBytes: 512 * 1_024 * 1_024 * 1_024,
                downloadBytesPerSecond: 2_048 * 1_024,
                uploadBytesPerSecond: 512 * 1_024,
                thermalState: "Fair"
            ),
            makeSample(
                capturedAt: makeDate(2026, 4, 22, 2, 0),
                cpuUsagePercent: 25,
                memoryUsedGB: 9,
                memoryTotalGB: 16,
                batteryLevelPercent: 60,
                powerUsageWatts: 11,
                freeDiskBytes: 285 * 1_024 * 1_024 * 1_024,
                totalDiskBytes: 512 * 1_024 * 1_024 * 1_024,
                downloadBytesPerSecond: 0,
                uploadBytesPerSecond: 0,
                powerSource: "AC Power"
            )
        ]

        let report = SystemReportGenerator.generate(from: samples, generatedAt: makeDate(2026, 4, 22, 3, 0))

        expect(report.contains("# Power Usage Report"), "report header missing")
        expect(report.contains("Samples stored: 3"), "sample count missing")
        expect(report.contains("System-power samples: 3"), "system-power sample count missing")
        expect(report.contains("Coverage: 2h 0m"), "coverage summary missing")
        expect(report.contains("- Average system power: 11.0 W"), "average system power summary incorrect")
        expect(report.contains("- Peak system power: 14.0 W"), "peak system power summary incorrect")
        expect(report.contains("- Latest system power: 11.0 W"), "latest system power summary incorrect")
        expect(report.contains("- Power source mix: AC Power 33% (1), Battery 67% (2)"), "power source mix summary incorrect")
        expect(report.contains("| Timestamp | System Power | Battery | Source |"), "peak moments table missing")
    }

    private static func testReportExcludesLegacyUnscopedPowerSamples() throws {
        let samples = [
            makeSample(
                capturedAt: makeDate(2026, 4, 22, 0, 0),
                cpuUsagePercent: 10,
                memoryUsedGB: 8,
                memoryTotalGB: 16,
                batteryLevelPercent: 90,
                powerUsageWatts: 18,
                freeDiskBytes: 300 * 1_024 * 1_024 * 1_024,
                totalDiskBytes: 512 * 1_024 * 1_024 * 1_024,
                downloadBytesPerSecond: 0,
                uploadBytesPerSecond: 0,
                powerMetricKind: nil,
                powerMetricSource: nil
            ),
            makeSample(
                capturedAt: makeDate(2026, 4, 22, 1, 0),
                cpuUsagePercent: 14,
                memoryUsedGB: 8.5,
                memoryTotalGB: 16,
                batteryLevelPercent: 88,
                powerUsageWatts: 10,
                freeDiskBytes: 299 * 1_024 * 1_024 * 1_024,
                totalDiskBytes: 512 * 1_024 * 1_024 * 1_024,
                downloadBytesPerSecond: 0,
                uploadBytesPerSecond: 0
            )
        ]

        let report = SystemReportGenerator.generate(from: samples, generatedAt: makeDate(2026, 4, 22, 2, 0))

        expect(
            report.contains("- Average system power: 10.0 W"),
            "legacy unscoped power samples should be excluded from the system-power trend"
        )
        expect(
            report.contains("Excluded legacy or unscoped power samples: 1"),
            "report should call out excluded legacy power samples"
        )
    }

    private static func testStorePrunesToRetentionLimit() throws {
        let fileManager = FileManager.default
        let tempDirectory = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = SystemHistoryStore(baseDirectoryURL: tempDirectory, retentionLimit: 2)

        try store.record(makeSample(
            capturedAt: makeDate(2026, 4, 22, 0, 0),
            cpuUsagePercent: 10,
            memoryUsedGB: 8,
            memoryTotalGB: 16,
            batteryLevelPercent: 90,
            powerUsageWatts: 7,
            freeDiskBytes: 300 * 1_024 * 1_024 * 1_024,
            totalDiskBytes: 512 * 1_024 * 1_024 * 1_024,
            downloadBytesPerSecond: 0,
            uploadBytesPerSecond: 0
        ))

        try store.record(makeSample(
            capturedAt: makeDate(2026, 4, 22, 0, 1),
            cpuUsagePercent: 20,
            memoryUsedGB: 8.5,
            memoryTotalGB: 16,
            batteryLevelPercent: 88,
            powerUsageWatts: 9,
            freeDiskBytes: 299 * 1_024 * 1_024 * 1_024,
            totalDiskBytes: 512 * 1_024 * 1_024 * 1_024,
            downloadBytesPerSecond: 0,
            uploadBytesPerSecond: 0
        ))

        try store.record(makeSample(
            capturedAt: makeDate(2026, 4, 22, 0, 2),
            cpuUsagePercent: 30,
            memoryUsedGB: 9,
            memoryTotalGB: 16,
            batteryLevelPercent: 85,
            powerUsageWatts: 12,
            freeDiskBytes: 298 * 1_024 * 1_024 * 1_024,
            totalDiskBytes: 512 * 1_024 * 1_024 * 1_024,
            downloadBytesPerSecond: 0,
            uploadBytesPerSecond: 0
        ))

        let samples = try store.loadSamples()
        expect(samples.count == 2, "retention limit should keep only 2 samples")
        expect(samples.first?.cpuUsagePercent == 20, "oldest sample should have been pruned")
        expect(fileManager.fileExists(atPath: store.historyURL.path), "history file should exist")
    }
}
