//
//  SystemInfoWidget.swift
//  SystemInfoWidget
//
//  Created by Daniel Ng Zheng Hui on 12/9/25.
//

import WidgetKit
import SwiftUI

struct SystemInfoEntry: TimelineEntry {
    let date: Date
    let snapshot: SystemInfoSnapshot
}

struct SystemInfoProviderTimeline: TimelineProvider {
    func placeholder(in context: Context) -> SystemInfoEntry {
        SystemInfoEntry(date: Date(), snapshot: .init(
            macOSVersion: "macOS 15.0",
            memoryUsage: "8.0 / 16.0 GB",
            uptime: "1d 2h 30m",
            freeDiskSpace: "256.0 GB",
            cpuUsage: "25%",
            totalDiskSpace: "500.0 GB",
            diskUsagePercent: 0.5
        ))
    }

    func getSnapshot(in context: Context, completion: @escaping (SystemInfoEntry) -> ()) {
        let entry = SystemInfoEntry(date: Date(), snapshot: SystemInfoProvider.snapshot())
        completion(entry)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SystemInfoEntry>) -> ()) {
        let now = Date()
        let entry = SystemInfoEntry(date: now, snapshot: SystemInfoProvider.snapshot())

        // Ask WidgetKit to refresh roughly every 5 minutes.
        let nextUpdate = Calendar.current.date(byAdding: .minute, value: 5, to: now) ?? now.addingTimeInterval(300)
        let timeline = Timeline(entries: [entry], policy: .after(nextUpdate))
        completion(timeline)
    }
}

// MARK: - Mini Circular Gauge for Widget

struct WidgetMiniGauge: View {
    let value: Double
    let icon: String
    let label: String
    let colors: [Color]
    
    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Circle()
                    .stroke(Color.gray.opacity(0.2), lineWidth: 4)
                
                Circle()
                    .trim(from: 0, to: value)
                    .stroke(
                        LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing),
                        style: StrokeStyle(lineWidth: 4, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(colors.first ?? .blue)
            }
            .frame(width: 36, height: 36)
            
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

// MARK: - Widget Stat Row

struct WidgetStatRow: View {
    let icon: String
    let label: String
    let value: String
    var iconColor: Color = .secondary
    
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(iconColor)
                .frame(width: 14)
            
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            
            Spacer(minLength: 4)
            
            Text(value)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
        }
    }
}

// MARK: - Small Widget View

struct SmallWidgetView: View {
    let entry: SystemInfoEntry
    
    private var cpuValue: Double {
        let cleaned = entry.snapshot.cpuUsage.replacingOccurrences(of: "%", with: "")
        return (Double(cleaned) ?? 0) / 100.0
    }
    
    private var diskPercent: String {
        String(format: "%.0f%%", entry.snapshot.diskUsagePercent * 100)
    }
    
    var body: some View {
        VStack(spacing: 6) {
            // Header
            HStack(spacing: 6) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [.blue, .purple],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 20, height: 20)
                    
                    Image(systemName: "gauge.with.dots.needle.67percent")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                }
                
                VStack(alignment: .leading, spacing: 0) {
                    Text("System")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                    HStack(spacing: 3) {
                        Circle()
                            .fill(.green)
                            .frame(width: 4, height: 4)
                        Text("Live")
                            .font(.system(size: 7))
                            .foregroundStyle(.secondary)
                    }
                }
                
                Spacer()
            }
            
            // Two gauges side by side
            HStack(spacing: 12) {
                WidgetMiniGauge(
                    value: cpuValue,
                    icon: "cpu",
                    label: entry.snapshot.cpuUsage,
                    colors: [.blue, .cyan]
                )
                
                WidgetMiniGauge(
                    value: entry.snapshot.diskUsagePercent,
                    icon: "internaldrive",
                    label: diskPercent,
                    colors: [.orange, .yellow]
                )
            }
            
            // Quick stats
            VStack(spacing: 2) {
                WidgetStatRow(
                    icon: "clock.arrow.circlepath",
                    label: "Up",
                    value: entry.snapshot.uptime,
                    iconColor: .teal
                )
                WidgetStatRow(
                    icon: "internaldrive.fill",
                    label: "Free",
                    value: entry.snapshot.freeDiskSpace,
                    iconColor: .green
                )
            }
        }
        .padding(10)
    }
}

// MARK: - Medium Widget View

struct MediumWidgetView: View {
    let entry: SystemInfoEntry
    
    private var cpuValue: Double {
        let cleaned = entry.snapshot.cpuUsage.replacingOccurrences(of: "%", with: "")
        return (Double(cleaned) ?? 0) / 100.0
    }
    
    private var diskPercent: String {
        String(format: "%.0f%%", entry.snapshot.diskUsagePercent * 100)
    }
    
    var body: some View {
        HStack(spacing: 16) {
            // Left side - Header and gauges
            VStack(alignment: .leading, spacing: 10) {
                // Header
                HStack(spacing: 6) {
                    ZStack {
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [.blue, .purple],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 24, height: 24)
                        
                        Image(systemName: "gauge.with.dots.needle.67percent")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    
                    VStack(alignment: .leading, spacing: 0) {
                        Text("System Monitor")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                        HStack(spacing: 3) {
                            Circle()
                                .fill(.green)
                                .frame(width: 4, height: 4)
                            Text("Live")
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                
                Spacer()
                
                // Gauges row - CPU and Disk
                HStack(spacing: 16) {
                    WidgetMiniGauge(
                        value: cpuValue,
                        icon: "cpu",
                        label: entry.snapshot.cpuUsage,
                        colors: [.blue, .cyan]
                    )
                    
                    WidgetMiniGauge(
                        value: entry.snapshot.diskUsagePercent,
                        icon: "internaldrive",
                        label: diskPercent,
                        colors: [.orange, .yellow]
                    )
                }
            }
            
            // Right side - Stats
            VStack(alignment: .leading, spacing: 6) {
                Text(entry.snapshot.macOSVersion)
                    .font(.system(size: 9, weight: .medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background {
                        Capsule()
                            .fill(Color.blue.opacity(0.15))
                    }
                    .foregroundStyle(.blue)
                
                Spacer(minLength: 4)
                
                VStack(spacing: 5) {
                    WidgetStatRow(
                        icon: "cpu",
                        label: "CPU",
                        value: entry.snapshot.cpuUsage,
                        iconColor: .blue
                    )
                    
                    WidgetStatRow(
                        icon: "clock.arrow.circlepath",
                        label: "Uptime",
                        value: entry.snapshot.uptime,
                        iconColor: .teal
                    )
                    
                    WidgetStatRow(
                        icon: "internaldrive.fill",
                        label: "Free",
                        value: entry.snapshot.freeDiskSpace,
                        iconColor: .green
                    )
                    
                    WidgetStatRow(
                        icon: "internaldrive",
                        label: "Total",
                        value: entry.snapshot.totalDiskSpace,
                        iconColor: .orange
                    )
                }
                
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
        .padding(14)
    }
}

// MARK: - Unified Entry View

struct SystemInfoWidgetEntryView: View {
    @Environment(\.widgetFamily) var family
    var entry: SystemInfoEntry

    var body: some View {
        switch family {
        case .systemSmall:
            SmallWidgetView(entry: entry)
        case .systemMedium:
            MediumWidgetView(entry: entry)
        default:
            SmallWidgetView(entry: entry)
        }
    }
}

struct SystemInfoWidget: Widget {
    let kind: String = "SystemInfoWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: SystemInfoProviderTimeline()) { entry in
            SystemInfoWidgetEntryView(entry: entry)
                .containerBackground(.ultraThinMaterial, for: .widget)
        }
        .configurationDisplayName("System Monitor")
        .description("Live system stats with a modern design.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
