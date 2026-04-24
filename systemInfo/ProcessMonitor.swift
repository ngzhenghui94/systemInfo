import Foundation
import Darwin

enum ProcessSignal: String, Equatable {
    case terminate
    case forceKill

    var rawSignal: Int32 {
        switch self {
        case .terminate:
            return SIGTERM
        case .forceKill:
            return SIGKILL
        }
    }

    var title: String {
        switch self {
        case .terminate:
            return "Terminate"
        case .forceKill:
            return "Force Kill"
        }
    }
}

struct ProcessMonitorRow: Equatable, Identifiable {
    let processID: pid_t
    let name: String
    let userName: String
    let cpuPercent: Double
    let memoryBytes: UInt64
    let state: String
    let executablePath: String

    var id: pid_t { processID }

    var cpuText: String {
        String(format: "%.1f%%", cpuPercent)
    }

    var memoryText: String {
        ProcessMonitorPresenter.formattedMemory(memoryBytes)
    }

    var executablePathText: String {
        executablePath.isEmpty ? "—" : executablePath
    }
}

enum ProcessTableSortKey: String, CaseIterable {
    case memory
    case cpu
    case name
    case processID
    case user
}

enum ProcessTableSortDirection: String, Equatable {
    case ascending
    case descending
}

struct ProcessTableSort: Equatable {
    let key: ProcessTableSortKey
    let direction: ProcessTableSortDirection

    static let defaultSort = ProcessTableSort(key: .memory, direction: .descending)

    func toggled(for selectedKey: ProcessTableSortKey) -> ProcessTableSort {
        if selectedKey == key {
            return ProcessTableSort(
                key: key,
                direction: direction == .ascending ? .descending : .ascending
            )
        }
        return ProcessTableSort(key: selectedKey, direction: selectedKey == .name ? .ascending : .descending)
    }
}

enum ProcessMonitorPresenter {
    static func displayRows(
        _ rows: [ProcessMonitorRow],
        query: String,
        sort: ProcessTableSort = .defaultSort
    ) -> [ProcessMonitorRow] {
        let filteredRows = filtered(rows, query: query)
        return filteredRows.sorted { lhs, rhs in
            compare(lhs, rhs, sort: sort)
        }
    }

    static func truncatedPath(_ path: String, maxLength: Int = 64) -> String {
        guard !path.isEmpty else {
            return "—"
        }
        guard path.count > maxLength, maxLength > 3 else {
            return path
        }

        let suffixLength = max(maxLength - 3, 1)
        return "..." + String(path.suffix(suffixLength))
    }

    static func formattedMemory(_ bytes: UInt64) -> String {
        guard bytes > 0 else {
            return "—"
        }

        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        formatter.countStyle = .memory
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter.string(fromByteCount: Int64(bytes))
    }

    private static func filtered(_ rows: [ProcessMonitorRow], query: String) -> [ProcessMonitorRow] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedQuery.isEmpty else {
            return rows
        }

        return rows.filter { row in
            row.name.lowercased().contains(normalizedQuery)
                || "\(row.processID)".contains(normalizedQuery)
                || row.executablePath.lowercased().contains(normalizedQuery)
        }
    }

    private static func compare(_ lhs: ProcessMonitorRow, _ rhs: ProcessMonitorRow, sort: ProcessTableSort) -> Bool {
        let result: ComparisonResult
        switch sort.key {
        case .memory:
            result = comparison(lhs.memoryBytes, rhs.memoryBytes)
        case .cpu:
            result = comparison(lhs.cpuPercent, rhs.cpuPercent)
        case .name:
            result = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
        case .processID:
            result = comparison(lhs.processID, rhs.processID)
        case .user:
            result = lhs.userName.localizedCaseInsensitiveCompare(rhs.userName)
        }

        if result == .orderedSame {
            return lhs.processID < rhs.processID
        }

        return sort.direction == .ascending
            ? result == .orderedAscending
            : result == .orderedDescending
    }

    private static func comparison<T: Comparable>(_ lhs: T, _ rhs: T) -> ComparisonResult {
        if lhs < rhs {
            return .orderedAscending
        }
        if lhs > rhs {
            return .orderedDescending
        }
        return .orderedSame
    }
}

struct ProcessTerminationValidation: Equatable {
    let isAllowed: Bool
    let message: String
}

struct ProcessTerminationResult: Equatable {
    let succeeded: Bool
    let message: String
}

enum ProcessTerminator {
    static func validateRequest(
        processID: pid_t,
        currentProcessID: pid_t = getpid()
    ) -> ProcessTerminationValidation {
        guard processID > 0 else {
            return ProcessTerminationValidation(isAllowed: false, message: "Invalid process identifier.")
        }

        guard processID != currentProcessID else {
            return ProcessTerminationValidation(isAllowed: false, message: "systemInfo will not terminate itself.")
        }

        return ProcessTerminationValidation(isAllowed: true, message: "")
    }

    static func terminate(processID: pid_t, signal: ProcessSignal) -> ProcessTerminationResult {
        let validation = validateRequest(processID: processID)
        guard validation.isAllowed else {
            return ProcessTerminationResult(succeeded: false, message: validation.message)
        }

        errno = 0
        let result = kill(processID, signal.rawSignal)
        if result == 0 {
            return ProcessTerminationResult(
                succeeded: true,
                message: "\(signal.title) sent to PID \(processID)."
            )
        }

        let errorText = String(cString: strerror(errno))
        return ProcessTerminationResult(
            succeeded: false,
            message: "\(signal.title) failed for PID \(processID): \(errorText)."
        )
    }
}

final class ProcessMonitorResolver {
    private struct TimingSample {
        let totalCPUTime: UInt64
        let capturedAt: Date
    }

    private var previousTimings: [pid_t: TimingSample] = [:]

    func snapshot(capturedAt: Date = Date()) -> [ProcessMonitorRow] {
        var nextTimings: [pid_t: TimingSample] = [:]

        let rows = Self.processIDs().compactMap { processID -> ProcessMonitorRow? in
            guard let info = Self.processInfo(for: processID, capturedAt: capturedAt, previousTiming: previousTimings[processID]) else {
                return nil
            }

            nextTimings[processID] = TimingSample(totalCPUTime: info.totalCPUTime, capturedAt: capturedAt)
            return info.row
        }

        previousTimings = nextTimings
        return rows
    }

    private static func processIDs() -> [pid_t] {
        let byteCount = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard byteCount > 0 else {
            return []
        }

        let pidCapacity = Int(byteCount) / MemoryLayout<pid_t>.stride
        var processIDs = [pid_t](repeating: 0, count: pidCapacity)

        let actualByteCount = processIDs.withUnsafeMutableBufferPointer { buffer -> Int32 in
            guard let baseAddress = buffer.baseAddress else {
                return 0
            }
            return proc_listpids(
                UInt32(PROC_ALL_PIDS),
                0,
                UnsafeMutableRawPointer(baseAddress),
                byteCount
            )
        }

        let actualCount = max(Int(actualByteCount) / MemoryLayout<pid_t>.stride, 0)
        return processIDs.prefix(actualCount).filter { $0 > 0 }
    }

    private static func processInfo(
        for processID: pid_t,
        capturedAt: Date,
        previousTiming: TimingSample?
    ) -> (row: ProcessMonitorRow, totalCPUTime: UInt64)? {
        let taskInfo = taskInfo(for: processID)
        let bsdInfo = bsdInfo(for: processID)
        let path = executablePath(for: processID)
        let name = processName(for: processID, path: path)

        guard !name.isEmpty else {
            return nil
        }

        let totalCPUTime = (taskInfo?.pti_total_user ?? 0) + (taskInfo?.pti_total_system ?? 0)
        let cpuPercent = cpuPercent(
            currentTotalTime: totalCPUTime,
            capturedAt: capturedAt,
            previousTiming: previousTiming
        )

        let row = ProcessMonitorRow(
            processID: processID,
            name: name,
            userName: userName(for: bsdInfo?.pbi_uid),
            cpuPercent: cpuPercent,
            memoryBytes: UInt64(taskInfo?.pti_resident_size ?? 0),
            state: stateText(from: bsdInfo?.pbi_status),
            executablePath: path
        )

        return (row, totalCPUTime)
    }

    private static func taskInfo(for processID: pid_t) -> proc_taskinfo? {
        var info = proc_taskinfo()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            proc_pidinfo(
                processID,
                PROC_PIDTASKINFO,
                0,
                pointer,
                Int32(MemoryLayout<proc_taskinfo>.size)
            )
        }

        return result == Int32(MemoryLayout<proc_taskinfo>.size) ? info : nil
    }

    private static func bsdInfo(for processID: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            proc_pidinfo(
                processID,
                PROC_PIDTBSDINFO,
                0,
                pointer,
                Int32(MemoryLayout<proc_bsdinfo>.size)
            )
        }

        return result == Int32(MemoryLayout<proc_bsdinfo>.size) ? info : nil
    }

    private static func processName(for processID: pid_t, path: String) -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        let result = proc_name(processID, &buffer, UInt32(buffer.count))
        if result > 0 {
            let name = String(cString: buffer).trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty {
                return name
            }
        }

        if !path.isEmpty {
            return URL(fileURLWithPath: path).lastPathComponent
        }

        return ""
    }

    private static func executablePath(for processID: pid_t) -> String {
        let bufferSize = Int(MAXPATHLEN) * 4
        var buffer = [CChar](repeating: 0, count: bufferSize)
        let result = proc_pidpath(processID, &buffer, UInt32(buffer.count))
        guard result > 0 else {
            return ""
        }

        return String(cString: buffer).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func userName(for userID: uid_t?) -> String {
        guard let userID else {
            return "—"
        }

        guard let password = getpwuid(userID),
              let name = password.pointee.pw_name else {
            return "\(userID)"
        }

        return String(cString: name)
    }

    private static func stateText(from status: UInt32?) -> String {
        guard let status else {
            return "Unknown"
        }

        switch Int32(status) {
        case SRUN:
            return "Running"
        case SSLEEP:
            return "Sleeping"
        case SSTOP:
            return "Stopped"
        case SZOMB:
            return "Zombie"
        default:
            return "Other"
        }
    }

    private static func cpuPercent(
        currentTotalTime: UInt64,
        capturedAt: Date,
        previousTiming: TimingSample?
    ) -> Double {
        guard let previousTiming,
              currentTotalTime >= previousTiming.totalCPUTime else {
            return 0
        }

        let elapsed = capturedAt.timeIntervalSince(previousTiming.capturedAt)
        guard elapsed > 0 else {
            return 0
        }

        let deltaNanoseconds = Double(currentTotalTime - previousTiming.totalCPUTime)
        return max((deltaNanoseconds / 1_000_000_000.0 / elapsed) * 100.0, 0)
    }
}
