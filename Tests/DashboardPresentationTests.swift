import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("Expectation failed: \(message)\n", stderr)
        exit(1)
    }
}

@main
struct DashboardPresentationTests {
    static func main() {
        testCriticalStatusUsesThermalAndCpuSignals()
        testFilteringMatchesTitlesAndKeywords()
        testHistorySubtitleHandlesPluralization()
        testCompactSidebarSummariesStayShort()
        testColumnCountBalancesDensityAndReadability()
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
}
