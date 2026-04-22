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
        expect(summary.highlights.contains("Power 38.0 W"), "power highlight missing")
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
}
