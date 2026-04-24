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
    loadAverageOneMinute: Double,
    loadAverageFiveMinute: Double,
    memoryUsedGB: Double,
    memoryTotalGB: Double,
    batteryLevelPercent: Double,
    powerUsageWatts: Double,
    downloadBytesPerSecond: Double,
    uploadBytesPerSecond: Double
) -> SystemHistorySample {
    let totalDiskBytes = Int64(512 * 1_024 * 1_024 * 1_024)
    let freeDiskBytes = Int64(300 * 1_024 * 1_024 * 1_024)

    return SystemHistorySample(
        capturedAt: capturedAt,
        hostName: "Studio-Mac",
        macOSVersion: "macOS 26.0",
        cpuModel: "M4 Pro",
        cpuCores: "12 cores",
        gpuName: "Apple GPU",
        cpuUsageText: "\(Int(cpuUsagePercent))%",
        cpuUsagePercent: cpuUsagePercent,
        loadAverageText: String(format: "%.2f, %.2f", loadAverageOneMinute, loadAverageFiveMinute),
        loadAverageOneMinute: loadAverageOneMinute,
        loadAverageFiveMinute: loadAverageFiveMinute,
        memoryUsageText: String(format: "%.1f / %.1f GB", memoryUsedGB, memoryTotalGB),
        memoryUsedGB: memoryUsedGB,
        memoryTotalGB: memoryTotalGB,
        batteryLevelText: "\(Int(batteryLevelPercent))%",
        batteryLevelPercent: batteryLevelPercent,
        powerSource: "Battery",
        powerUsageText: String(format: "%.1f W", powerUsageWatts),
        powerUsageWatts: powerUsageWatts,
        powerMetricKind: .systemPower,
        powerMetricSource: "AppleSmartBattery/BatteryData.SystemPower",
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
        thermalState: "Normal",
        ipAddress: "192.168.1.20",
        wifiNetwork: "OfficeNet",
        freeMemoryText: "10.0 / 18.0 GB"
    )
}

@main
struct DashboardPresentationTests {
    static func main() {
        testCriticalStatusUsesThermalAndCpuSignals()
        testFilteringMatchesTitlesAndKeywords()
        testHistorySubtitleHandlesPluralization()
        testCompactSidebarSummariesStayShort()
        testColumnCountBalancesDensityAndReadability()
        testTrendWindowSubtitleReflectsDisplayedWindow()
        testTrendCardsUseRecentSamplesAndFormatDelta()
        print("Dashboard presentation tests passed")
    }

    private static func testCriticalStatusUsesThermalAndCpuSignals() {
        let summary = DashboardPresentationBuilder.healthSummary(
            cpuUsagePercent: 92,
            batteryLevelPercent: 18,
            thermalState: "Critical",
            powerUsageWatts: 38
        )

        expect(summary.tone == .critical, "critical thermal state should escalate tone")
        expect(summary.title == "System under pressure", "critical title mismatch")
        expect(summary.highlights.contains("CPU 92%"), "cpu highlight missing")
        expect(summary.highlights.contains("System Power 38.0 W"), "power highlight missing")
    }

    private static func testFilteringMatchesTitlesAndKeywords() {
        let sections = DashboardPresentationBuilder.filteredSections(matching: "report")
        expect(sections.contains(.history), "history section should match report keyword")
        expect(!sections.contains(.network), "network should not match report keyword")
    }

    private static func testHistorySubtitleHandlesPluralization() {
        expect(
            DashboardPresentationBuilder.historySubtitle(sampleCount: 1, coverageText: "5m") == "1 sample captured over 5m",
            "single sample subtitle mismatch"
        )
        expect(
            DashboardPresentationBuilder.historySubtitle(sampleCount: 12, coverageText: "2h 0m") == "12 samples captured over 2h 0m",
            "plural sample subtitle mismatch"
        )
    }

    private static func testCompactSidebarSummariesStayShort() {
        let summary = DashboardHealthSummary(
            tone: .elevated,
            title: "System needs attention",
            subtitle: "One or more signals are trending away from nominal.",
            highlights: []
        )

        expect(
            DashboardPresentationBuilder.compactSectionSummary(
                for: .performance,
                healthSummary: summary,
                cpuUsageText: "27%",
                memoryPercentText: "85%",
                powerUsageText: "—",
                powerSource: "AC Power",
                downloadSpeedText: "58.1 KB/s",
                uploadSpeedText: "31.0 KB/s",
                sampleCount: 2,
                coverageText: "1m"
            ) == "CPU 27% · MEM 85%",
            "performance compact summary mismatch"
        )

        expect(
            DashboardPresentationBuilder.compactSectionSummary(
                for: .network,
                healthSummary: summary,
                cpuUsageText: "27%",
                memoryPercentText: "85%",
                powerUsageText: "—",
                powerSource: "AC Power",
                downloadSpeedText: "58.1 KB/s",
                uploadSpeedText: "31.0 KB/s",
                sampleCount: 2,
                coverageText: "1m"
            ) == "58.1K↓ · 31.0K↑",
            "network compact summary mismatch"
        )

        expect(
            DashboardPresentationBuilder.compactSectionSummary(
                for: .history,
                healthSummary: summary,
                cpuUsageText: "27%",
                memoryPercentText: "85%",
                powerUsageText: "—",
                powerSource: "AC Power",
                downloadSpeedText: "58.1 KB/s",
                uploadSpeedText: "31.0 KB/s",
                sampleCount: 2,
                coverageText: "1m"
            ) == "2 samples · 1m",
            "history compact summary mismatch"
        )
    }

    private static func testColumnCountBalancesDensityAndReadability() {
        expect(
            DashboardPresentationBuilder.columnCount(for: 540, minimumCardWidth: 280, maxColumns: 3) == 1,
            "narrow widths should collapse to one column"
        )

        expect(
            DashboardPresentationBuilder.columnCount(for: 900, minimumCardWidth: 280, maxColumns: 3) == 3,
            "wide gauge rows should use three columns when the cards fit"
        )

        expect(
            DashboardPresentationBuilder.columnCount(for: 900, minimumCardWidth: 360, maxColumns: 3) == 2,
            "dense fact cards should step down to two columns for readability"
        )
    }

    private static func testTrendWindowSubtitleReflectsDisplayedWindow() {
        expect(
            DashboardPresentationBuilder.trendWindowSubtitle(totalSampleCount: 18, displayedSampleCount: 18) == "Showing all 18 saved samples.",
            "subtitle should acknowledge when all saved samples are visible"
        )

        expect(
            DashboardPresentationBuilder.trendWindowSubtitle(totalSampleCount: 144, displayedSampleCount: 60) == "Showing the latest 60 of 144 saved samples.",
            "subtitle should describe the recent chart window"
        )
    }

    private static func testTrendCardsUseRecentSamplesAndFormatDelta() {
        let samples = [
            makeSample(
                capturedAt: makeDate(2026, 4, 22, 0, 0),
                cpuUsagePercent: 12,
                loadAverageOneMinute: 0.8,
                loadAverageFiveMinute: 0.7,
                memoryUsedGB: 7,
                memoryTotalGB: 16,
                batteryLevelPercent: 92,
                powerUsageWatts: 8,
                downloadBytesPerSecond: 128 * 1_024,
                uploadBytesPerSecond: 64 * 1_024
            ),
            makeSample(
                capturedAt: makeDate(2026, 4, 22, 0, 1),
                cpuUsagePercent: 24,
                loadAverageOneMinute: 1.1,
                loadAverageFiveMinute: 0.9,
                memoryUsedGB: 8,
                memoryTotalGB: 16,
                batteryLevelPercent: 88,
                powerUsageWatts: 11,
                downloadBytesPerSecond: 256 * 1_024,
                uploadBytesPerSecond: 80 * 1_024
            ),
            makeSample(
                capturedAt: makeDate(2026, 4, 22, 0, 2),
                cpuUsagePercent: 41,
                loadAverageOneMinute: 1.35,
                loadAverageFiveMinute: 1.05,
                memoryUsedGB: 9,
                memoryTotalGB: 16,
                batteryLevelPercent: 84,
                powerUsageWatts: 16,
                downloadBytesPerSecond: 512 * 1_024,
                uploadBytesPerSecond: 96 * 1_024
            )
        ]

        let recent = DashboardPresentationBuilder.recentSamples(samples, limit: 2)
        expect(recent.count == 2, "recent sample window should keep the requested suffix")
        expect(recent.first?.capturedAt == samples[1].capturedAt, "recent window should start from the newest suffix")

        let trendCards = DashboardPresentationBuilder.trendCards(from: samples, limit: 2)
        expect(trendCards.count == 7, "all metrics with two recent points should produce chart cards")

        let cpuCard = trendCards.first { $0.metric == .cpuUsage }
        expect(cpuCard?.currentValueText == "41%", "cpu card should show latest value")
        expect(cpuCard?.deltaText == "+17 pts", "cpu delta should compare against the displayed window")
        expect(cpuCard?.points.count == 2, "cpu chart should use the recent sample window")

        let loadCard = trendCards.filter { $0.metric == .cpuLoad }.first
        expect(loadCard?.currentValueText == "1.35", "load card should show the latest one-minute load average")
        expect(loadCard?.deltaText == "+0.25", "load delta should preserve two-decimal precision")

        let powerCard = trendCards.first { $0.metric == .systemPower }
        expect(powerCard?.currentValueText == "16.0 W", "power card should show watt text")
        expect(powerCard?.deltaText == "+5.0 W", "power delta should preserve unit precision")

        let downloadCard = trendCards.first { $0.metric == .downloadRate }
        expect(downloadCard?.currentValueText == "512.0 KB/s", "throughput card should format bytes per second")
    }
}
