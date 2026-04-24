import Foundation

enum PowerUsageTrendDirection: String, Equatable {
    case rising
    case falling
    case stable
    case unavailable

    var title: String {
        switch self {
        case .rising:
            return "Rising"
        case .falling:
            return "Falling"
        case .stable:
            return "Stable"
        case .unavailable:
            return "Unavailable"
        }
    }
}

struct PowerUsageTrendPoint: Equatable, Identifiable {
    let capturedAt: Date
    let watts: Double

    var id: Date { capturedAt }
}

struct PowerUsageTrendBucket: Equatable, Identifiable {
    let label: String
    let averageWatts: Double
    let minimumWatts: Double
    let maximumWatts: Double
    let sampleCount: Int

    var id: String { label }
}

struct PowerUsagePeakMoment: Equatable, Identifiable {
    let capturedAt: Date
    let watts: Double
    let batteryLevelPercent: Double?
    let powerSource: String

    var id: String {
        "\(capturedAt.timeIntervalSinceReferenceDate)-\(watts)"
    }
}

struct PowerUsageSourceBreakdown: Equatable, Identifiable {
    let label: String
    let count: Int
    let share: Double

    var id: String { label }
}

struct PowerUsageReportSnapshot: Equatable {
    let sampleCount: Int
    let powerSampleCount: Int
    let excludedPowerSampleCount: Int
    let firstCapturedAt: Date?
    let lastCapturedAt: Date?
    let coverageText: String
    let averageWatts: Double?
    let minimumWatts: Double?
    let maximumWatts: Double?
    let latestWatts: Double?
    let averageBatteryPercent: Double?
    let batteryDeltaPercent: Double?
    let trendDirection: PowerUsageTrendDirection
    let trendDeltaWatts: Double?
    let trendPoints: [PowerUsageTrendPoint]
    let trendBuckets: [PowerUsageTrendBucket]
    let peakMoments: [PowerUsagePeakMoment]
    let powerSourceBreakdown: [PowerUsageSourceBreakdown]

    static let empty = PowerUsageReportSnapshot(
        sampleCount: 0,
        powerSampleCount: 0,
        excludedPowerSampleCount: 0,
        firstCapturedAt: nil,
        lastCapturedAt: nil,
        coverageText: "0m",
        averageWatts: nil,
        minimumWatts: nil,
        maximumWatts: nil,
        latestWatts: nil,
        averageBatteryPercent: nil,
        batteryDeltaPercent: nil,
        trendDirection: .unavailable,
        trendDeltaWatts: nil,
        trendPoints: [],
        trendBuckets: [],
        peakMoments: [],
        powerSourceBreakdown: []
    )
}

enum PowerUsageReportBuilder {
    static func build(from samples: [SystemHistorySample]) -> PowerUsageReportSnapshot {
        let sortedSamples = samples.sorted { $0.capturedAt < $1.capturedAt }
        let scopedPowerSamples = sortedSamples.filter {
            $0.powerMetricKind == .systemPower && $0.powerUsageWatts != nil
        }

        guard !scopedPowerSamples.isEmpty else {
            return PowerUsageReportSnapshot(
                sampleCount: sortedSamples.count,
                powerSampleCount: 0,
                excludedPowerSampleCount: sortedSamples.filter {
                    $0.powerUsageWatts != nil && $0.powerMetricKind != .systemPower
                }.count,
                firstCapturedAt: nil,
                lastCapturedAt: nil,
                coverageText: "0m",
                averageWatts: nil,
                minimumWatts: nil,
                maximumWatts: nil,
                latestWatts: nil,
                averageBatteryPercent: average(sortedSamples.compactMap(\.batteryLevelPercent)),
                batteryDeltaPercent: batteryDelta(from: sortedSamples),
                trendDirection: .unavailable,
                trendDeltaWatts: nil,
                trendPoints: [],
                trendBuckets: [],
                peakMoments: [],
                powerSourceBreakdown: []
            )
        }

        let overview = SystemHistoryOverview(
            sampleCount: scopedPowerSamples.count,
            firstCapturedAt: scopedPowerSamples.first?.capturedAt,
            lastCapturedAt: scopedPowerSamples.last?.capturedAt
        )
        let powerValues = scopedPowerSamples.compactMap(\.powerUsageWatts)
        let powerSummary = summarize(powerValues)
        let trendPoints = Array(scopedPowerSamples.suffix(24)).map { sample in
            PowerUsageTrendPoint(capturedAt: sample.capturedAt, watts: sample.powerUsageWatts ?? 0)
        }
        let recentTrend = summarizeTrend(from: trendPoints)

        return PowerUsageReportSnapshot(
            sampleCount: sortedSamples.count,
            powerSampleCount: scopedPowerSamples.count,
            excludedPowerSampleCount: sortedSamples.filter {
                $0.powerUsageWatts != nil && $0.powerMetricKind != .systemPower
            }.count,
            firstCapturedAt: scopedPowerSamples.first?.capturedAt,
            lastCapturedAt: scopedPowerSamples.last?.capturedAt,
            coverageText: overview.coverageText,
            averageWatts: powerSummary?.average,
            minimumWatts: powerSummary?.minimum,
            maximumWatts: powerSummary?.maximum,
            latestWatts: powerSummary?.latest,
            averageBatteryPercent: average(scopedPowerSamples.compactMap(\.batteryLevelPercent)),
            batteryDeltaPercent: batteryDelta(from: scopedPowerSamples),
            trendDirection: recentTrend.direction,
            trendDeltaWatts: recentTrend.deltaWatts,
            trendPoints: trendPoints,
            trendBuckets: makeTrendBuckets(from: trendPoints, maxBuckets: 6),
            peakMoments: scopedPowerSamples
                .compactMap { sample in
                    guard let watts = sample.powerUsageWatts else {
                        return nil
                    }
                    return PowerUsagePeakMoment(
                        capturedAt: sample.capturedAt,
                        watts: watts,
                        batteryLevelPercent: sample.batteryLevelPercent,
                        powerSource: sample.powerSource
                    )
                }
                .sorted { lhs, rhs in
                    if lhs.watts == rhs.watts {
                        return lhs.capturedAt > rhs.capturedAt
                    }
                    return lhs.watts > rhs.watts
                }
                .prefix(3)
                .map { $0 },
            powerSourceBreakdown: summarizeSources(from: scopedPowerSamples)
        )
    }

    static func displayTimestamp(for date: Date, includeDate: Bool = false) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale.autoupdatingCurrent
        formatter.timeZone = .autoupdatingCurrent
        formatter.setLocalizedDateFormatFromTemplate(includeDate ? "MMM d h:mm a" : "h:mm a")
        return formatter.string(from: date)
    }

    private struct NumericSummary {
        let average: Double
        let minimum: Double
        let maximum: Double
        let latest: Double
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

    private static func average(_ values: [Double]) -> Double? {
        guard !values.isEmpty else {
            return nil
        }
        return values.reduce(0, +) / Double(values.count)
    }

    private static func batteryDelta(from samples: [SystemHistorySample]) -> Double? {
        guard let first = samples.first?.batteryLevelPercent,
              let last = samples.last?.batteryLevelPercent else {
            return nil
        }
        return last - first
    }

    private static func summarizeTrend(from trendPoints: [PowerUsageTrendPoint]) -> (direction: PowerUsageTrendDirection, deltaWatts: Double?) {
        let recentPoints = Array(trendPoints.suffix(8))
        guard recentPoints.count >= 3 else {
            return (.unavailable, nil)
        }

        let midpoint = recentPoints.count / 2
        let leadingAverage = average(recentPoints.prefix(midpoint).map(\.watts)) ?? 0
        let trailingAverage = average(recentPoints.suffix(recentPoints.count - midpoint).map(\.watts)) ?? 0
        let delta = trailingAverage - leadingAverage

        if delta >= 1.5 {
            return (.rising, delta)
        }
        if delta <= -1.5 {
            return (.falling, delta)
        }
        return (.stable, delta)
    }

    private static func makeTrendBuckets(from trendPoints: [PowerUsageTrendPoint], maxBuckets: Int) -> [PowerUsageTrendBucket] {
        guard !trendPoints.isEmpty else {
            return []
        }

        let bucketCount = max(1, min(maxBuckets, trendPoints.count))
        let bucketSize = Int(ceil(Double(trendPoints.count) / Double(bucketCount)))

        return stride(from: 0, to: trendPoints.count, by: bucketSize).compactMap { startIndex in
            let endIndex = min(startIndex + bucketSize, trendPoints.count)
            let bucketPoints = Array(trendPoints[startIndex..<endIndex])
            guard let summary = summarize(bucketPoints.map(\.watts)),
                  let firstPoint = bucketPoints.first,
                  let lastPoint = bucketPoints.last else {
                return nil
            }

            let label: String
            if Calendar.autoupdatingCurrent.isDate(firstPoint.capturedAt, inSameDayAs: lastPoint.capturedAt) {
                label = "\(displayTimestamp(for: firstPoint.capturedAt)) - \(displayTimestamp(for: lastPoint.capturedAt))"
            } else {
                label = "\(displayTimestamp(for: firstPoint.capturedAt, includeDate: true)) - \(displayTimestamp(for: lastPoint.capturedAt))"
            }

            return PowerUsageTrendBucket(
                label: label,
                averageWatts: summary.average,
                minimumWatts: summary.minimum,
                maximumWatts: summary.maximum,
                sampleCount: bucketPoints.count
            )
        }
    }

    private static func summarizeSources(from samples: [SystemHistorySample]) -> [PowerUsageSourceBreakdown] {
        guard !samples.isEmpty else {
            return []
        }

        let counts = samples.reduce(into: [String: Int]()) { partialResult, sample in
            let label = sample.powerSource.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty, label != "—" else {
                return
            }
            partialResult[label, default: 0] += 1
        }

        return counts
            .sorted { lhs, rhs in
                if lhs.key == rhs.key {
                    return lhs.value < rhs.value
                }
                return lhs.key < rhs.key
            }
            .map { key, value in
                PowerUsageSourceBreakdown(
                    label: key,
                    count: value,
                    share: Double(value) / Double(samples.count)
                )
            }
    }
}

enum PowerUsageReportGenerator {
    static func generate(from samples: [SystemHistorySample], generatedAt: Date = Date()) -> String {
        let snapshot = PowerUsageReportBuilder.build(from: samples)

        var lines: [String] = [
            "# Power Usage Report",
            "",
            "Generated: \(format(date: generatedAt))",
            "Samples stored: \(snapshot.sampleCount)",
            "System-power samples: \(snapshot.powerSampleCount)",
            "Excluded legacy or unscoped power samples: \(snapshot.excludedPowerSampleCount)"
        ]

        if let firstCapturedAt = snapshot.firstCapturedAt, let lastCapturedAt = snapshot.lastCapturedAt {
            lines.append("Range: \(format(date: firstCapturedAt)) -> \(format(date: lastCapturedAt))")
            lines.append("Coverage: \(snapshot.coverageText)")
        }

        guard snapshot.powerSampleCount > 0 else {
            lines.append("")
            lines.append("No scoped system-power samples have been captured yet.")
            return lines.joined(separator: "\n")
        }

        lines.append("")
        lines.append("## Summary")
        lines.append("- Average system power: \(formatWatts(snapshot.averageWatts))")
        lines.append("- Lowest system power: \(formatWatts(snapshot.minimumWatts))")
        lines.append("- Peak system power: \(formatWatts(snapshot.maximumWatts))")
        lines.append("- Latest system power: \(formatWatts(snapshot.latestWatts))")
        lines.append("- Recent trend: \(formatTrend(direction: snapshot.trendDirection, deltaWatts: snapshot.trendDeltaWatts))")
        lines.append("- Average battery level: \(formatPercent(snapshot.averageBatteryPercent))")
        lines.append("- Battery change across range: \(formatSignedPercent(snapshot.batteryDeltaPercent))")

        if !snapshot.powerSourceBreakdown.isEmpty {
            let sourceMix = snapshot.powerSourceBreakdown
                .map { source in
                    String(format: "%@ %.0f%% (%d)", source.label, source.share * 100, source.count)
                }
                .joined(separator: ", ")
            lines.append("- Power source mix: \(sourceMix)")
        }

        if !snapshot.trendBuckets.isEmpty {
            lines.append("")
            lines.append("## Trend Windows")
            lines.append("| Window | Avg System Power | Range | Samples |")
            lines.append("| --- | ---: | ---: | ---: |")
            for bucket in snapshot.trendBuckets {
                lines.append(
                    "| \(bucket.label) | \(String(format: "%.1f W", bucket.averageWatts)) | \(String(format: "%.1f-%.1f W", bucket.minimumWatts, bucket.maximumWatts)) | \(bucket.sampleCount) |"
                )
            }
        }

        if !snapshot.peakMoments.isEmpty {
            lines.append("")
            lines.append("## Peak Moments")
            lines.append("| Timestamp | System Power | Battery | Source |")
            lines.append("| --- | ---: | ---: | --- |")
            for moment in snapshot.peakMoments {
                lines.append(
                    "| \(format(date: moment.capturedAt)) | \(String(format: "%.1f W", moment.watts)) | \(formatPercent(moment.batteryLevelPercent)) | \(moment.powerSource) |"
                )
            }
        }

        return lines.joined(separator: "\n")
    }

    private static func format(date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    private static func formatWatts(_ watts: Double?) -> String {
        guard let watts else {
            return "—"
        }
        return String(format: "%.1f W", watts)
    }

    private static func formatPercent(_ percent: Double?) -> String {
        guard let percent else {
            return "—"
        }
        return String(format: "%.1f%%", percent)
    }

    private static func formatSignedPercent(_ percent: Double?) -> String {
        guard let percent else {
            return "—"
        }

        if percent > 0 {
            return String(format: "+%.1f%%", percent)
        }
        return String(format: "%.1f%%", percent)
    }

    private static func formatTrend(direction: PowerUsageTrendDirection, deltaWatts: Double?) -> String {
        switch direction {
        case .rising:
            return "Rising (\(formatSignedWatts(deltaWatts)))"
        case .falling:
            return "Falling (\(formatSignedWatts(deltaWatts)))"
        case .stable:
            return "Stable (\(formatSignedWatts(deltaWatts)))"
        case .unavailable:
            return "Unavailable"
        }
    }

    private static func formatSignedWatts(_ watts: Double?) -> String {
        guard let watts else {
            return "—"
        }

        if watts > 0 {
            return String(format: "+%.1f W", watts)
        }
        return String(format: "%.1f W", watts)
    }
}
