import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("Expectation failed: \(message)\n", stderr)
        exit(1)
    }
}

@main
struct ProcessMonitorTests {
    static func main() {
        testRowsDefaultToMemoryDescendingAndSearchNamePIDPath()
        testPathTruncationKeepsFileNameVisible()
        testTerminatorRefusesToKillCurrentProcess()
        testResolverIncludesCurrentProcess()
        print("Process monitor tests passed")
    }

    private static func testRowsDefaultToMemoryDescendingAndSearchNamePIDPath() {
        let rows = [
            ProcessMonitorRow(
                processID: 101,
                name: "WindowServer",
                userName: "root",
                cpuPercent: 4.2,
                memoryBytes: 600_000_000,
                state: "Running",
                executablePath: "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/Resources/WindowServer"
            ),
            ProcessMonitorRow(
                processID: 202,
                name: "Code Helper",
                userName: "daniel",
                cpuPercent: 18.0,
                memoryBytes: 1_800_000_000,
                state: "Sleeping",
                executablePath: "/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper.app/Contents/MacOS/Code Helper"
            ),
            ProcessMonitorRow(
                processID: 303,
                name: "systemInfo",
                userName: "daniel",
                cpuPercent: 2.1,
                memoryBytes: 240_000_000,
                state: "Running",
                executablePath: "/Applications/systemInfo.app/Contents/MacOS/systemInfo"
            )
        ]

        let defaultRows = ProcessMonitorPresenter.displayRows(rows, query: "")
        expect(defaultRows.map(\.processID) == [202, 101, 303], "default sort should be memory descending")

        let pidSearch = ProcessMonitorPresenter.displayRows(rows, query: "303")
        expect(pidSearch.map(\.name) == ["systemInfo"], "search should match PID text")

        let nameSearch = ProcessMonitorPresenter.displayRows(rows, query: "code")
        expect(nameSearch.map(\.processID) == [202], "search should match process name")

        let pathSearch = ProcessMonitorPresenter.displayRows(rows, query: "skylight")
        expect(pathSearch.map(\.processID) == [101], "search should match executable path")
    }

    private static func testPathTruncationKeepsFileNameVisible() {
        let path = "/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper.app/Contents/MacOS/Code Helper"
        let truncated = ProcessMonitorPresenter.truncatedPath(path, maxLength: 42)

        expect(truncated.hasPrefix("..."), "truncated path should show omitted prefix")
        expect(truncated.hasSuffix("Code Helper"), "truncated path should keep executable name visible")
        expect(truncated.count <= 42, "truncated path should respect the requested display width")
    }

    private static func testTerminatorRefusesToKillCurrentProcess() {
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let validation = ProcessTerminator.validateRequest(processID: currentPID, currentProcessID: currentPID)

        expect(!validation.isAllowed, "terminator should refuse to kill the current app process")
        expect(validation.message.contains("itself"), "self-kill refusal should explain the reason")
    }

    private static func testResolverIncludesCurrentProcess() {
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let rows = ProcessMonitorResolver().snapshot()

        expect(rows.contains { $0.processID == currentPID }, "process resolver should include the current process")
    }
}
