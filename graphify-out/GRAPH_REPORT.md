# Graph Report - /Users/icelemontees/Projects/systemInfo  (2026-04-24)

## Corpus Check
- Corpus is ~21,072 words - fits in a single context window. You may not need a graph.

## Summary
- 302 nodes · 590 edges · 18 communities detected
- Extraction: 98% EXTRACTED · 2% INFERRED · 0% AMBIGUOUS · INFERRED: 11 edges (avg confidence: 0.85)
- Token cost: 0 input · 0 output

## Community Hubs (Navigation)
- [[_COMMUNITY_Content Dashboard UI|Content Dashboard UI]]
- [[_COMMUNITY_Dashboard Metrics Model|Dashboard Metrics Model]]
- [[_COMMUNITY_System Monitoring Engine|System Monitoring Engine]]
- [[_COMMUNITY_Dashboard Presentation Logic|Dashboard Presentation Logic]]
- [[_COMMUNITY_History Storage Reports|History Storage Reports]]
- [[_COMMUNITY_Power Telemetry Parsing|Power Telemetry Parsing]]
- [[_COMMUNITY_Widget App Intent|Widget App Intent]]
- [[_COMMUNITY_Dashboard Presentation Tests|Dashboard Presentation Tests]]
- [[_COMMUNITY_Network Details Resolution|Network Details Resolution]]
- [[_COMMUNITY_Power Report Tests|Power Report Tests]]
- [[_COMMUNITY_Monitoring History Tests|Monitoring History Tests]]
- [[_COMMUNITY_Widget System Snapshot|Widget System Snapshot]]
- [[_COMMUNITY_App Icon Design|App Icon Design]]
- [[_COMMUNITY_Power Telemetry Tests|Power Telemetry Tests]]
- [[_COMMUNITY_Network Details Tests|Network Details Tests]]
- [[_COMMUNITY_Main App Snapshot Model|Main App Snapshot Model]]
- [[_COMMUNITY_Widget Bundle|Widget Bundle]]
- [[_COMMUNITY_Terminal Notebook Export|Terminal Notebook Export]]

## God Nodes (most connected - your core abstractions)
1. `SystemInfoViewModel` - 39 edges
2. `ContentView` - 25 edges
3. `DashboardPresentationBuilder` - 23 edges
4. `SystemHistoryStore` - 18 edges
5. `PowerUsageReportBuilder` - 16 edges
6. `NetworkDetailsResolver` - 14 edges
7. `PowerTelemetryParser` - 14 edges
8. `PowerUsageReportGenerator` - 12 edges
9. `DashboardTrendMetric` - 11 edges
10. `SystemHistorySample` - 10 edges

## Surprising Connections (you probably didn't know these)
- `SystemInfoSnapshot (App)` --semantically_similar_to--> `SystemInfoSnapshot (Widget)`  [INFERRED] [semantically similar]
  systemInfo/SystemInfoModel.swift → SystemInfoWidget/WidgetSystemInfoModel.swift
- `SystemInfoProvider (App)` --semantically_similar_to--> `SystemInfoProvider (Widget)`  [INFERRED] [semantically similar]
  systemInfo/SystemInfoModel.swift → SystemInfoWidget/WidgetSystemInfoModel.swift
- `MonitoringHistoryTests` --references--> `SystemHistoryStore`  [EXTRACTED]
  Tests/MonitoringHistoryTests.swift → systemInfo/MonitoringHistory.swift
- `PowerUsageReportTests` --references--> `PowerUsageReportBuilder`  [EXTRACTED]
  Tests/PowerUsageReportTests.swift → systemInfo/PowerUsageReport.swift
- `PowerUsageReportBuilder` --semantically_similar_to--> `DashboardPresentationBuilder`  [INFERRED] [semantically similar]
  systemInfo/PowerUsageReport.swift → systemInfo/DashboardPresentation.swift

## Hyperedges (group relationships)
- **History Capture And Reporting** — contentview_systeminfoviewmodel, monitoringhistory_systemhistorystore, monitoringhistory_systemhistorysample, powerusagereport_powerusagereportgenerator [EXTRACTED 1.00]
- **Dashboard History Analysis** — contentview_contentview, dashboardpresentation_dashboardpresentationbuilder, powerusagereport_powerusagereportbuilder, monitoringhistory_systemhistorysample [INFERRED 0.82]
- **Widget Refresh Loop** — systeminfowidget_systeminfowidget, systeminfowidget_systeminfoprovidertimeline, widgetmodel_systeminfoprovider_widget [EXTRACTED 1.00]
- **Hardware Status Iconography** — systeminfo_app_icon, systeminfo_cpu_package, systeminfo_memory_module, systeminfo_circuit_traces [INFERRED 0.86]

## Communities

### Community 0 - "Content Dashboard UI"
Cohesion: 0.08
Nodes (23): App, CircularGaugeView, ContentView, DashboardFactsCard, DashboardGaugeCard, DashboardHeroCard, DashboardHeroFactRow, DashboardPanelHeader (+15 more)

### Community 1 - "Dashboard Metrics Model"
Cohesion: 0.08
Nodes (31): CaseIterable, DashboardSection, history, network, overview, performance, power, DashboardTrendCardModel (+23 more)

### Community 2 - "System Monitoring Engine"
Cohesion: 0.13
Nodes (3): NetworkMonitor, SystemInfoViewModel, ObservableObject

### Community 3 - "Dashboard Presentation Logic"
Cohesion: 0.11
Nodes (9): DashboardHealthSummary, DashboardPresentationBuilder, DashboardTone, critical, elevated, nominal, PowerUsageReportGenerator, String (+1 more)

### Community 4 - "History Storage Reports"
Cohesion: 0.16
Nodes (6): SystemHistoryOverview, SystemHistorySample, SystemHistoryStore, SystemReportGenerator, MonitoringHistoryTests, PowerUsageReportTests

### Community 5 - "Power Telemetry Parsing"
Cohesion: 0.2
Nodes (7): Codable, PowerMetricKind, systemPower, PowerTelemetryParser, PowerTelemetryResolver, PowerTelemetrySnapshot, PowerTelemetryTests

### Community 6 - "Widget App Intent"
Cohesion: 0.14
Nodes (13): ConfigurationAppIntent, SystemInfoProvider (App), SystemInfoSnapshot (App), SystemInfoEntry, SystemInfoProviderTimeline, SystemInfoWidget, TimelineEntry, TimelineProvider (+5 more)

### Community 7 - "Dashboard Presentation Tests"
Cohesion: 0.36
Nodes (4): DashboardPresentationTests, expect(), makeDate(), makeSample()

### Community 8 - "Network Details Resolution"
Cohesion: 0.27
Nodes (2): NetworkDetailsResolver, NetworkDetailsTests

### Community 9 - "Power Report Tests"
Cohesion: 0.49
Nodes (5): expect(), expectNear(), makeDate(), makeSample(), PowerUsageReportTests

### Community 10 - "Monitoring History Tests"
Cohesion: 0.56
Nodes (4): expect(), makeDate(), makeSample(), MonitoringHistoryTests

### Community 11 - "Widget System Snapshot"
Cohesion: 0.43
Nodes (2): SystemInfoProvider, SystemInfoSnapshot

### Community 12 - "App Icon Design"
Cohesion: 0.36
Nodes (8): SystemInfo App Icon, Circuit Trace Network, CPU Package, Composite Hardware Diagnostics Metaphor, Hardware Monitoring, Information Badge, Memory Module, Settings Gear

### Community 13 - "Power Telemetry Tests"
Cohesion: 0.57
Nodes (2): expect(), PowerTelemetryTests

### Community 14 - "Network Details Tests"
Cohesion: 0.57
Nodes (2): expect(), NetworkDetailsTests

### Community 15 - "Main App Snapshot Model"
Cohesion: 0.53
Nodes (2): SystemInfoProvider, SystemInfoSnapshot

### Community 16 - "Widget Bundle"
Cohesion: 0.67
Nodes (2): SystemInfoWidgetBundle, WidgetBundle

### Community 17 - "Terminal Notebook Export"
Cohesion: 1.0
Nodes (1): Empty Terminal Notebook Export

## Ambiguous Edges - Review These
- `SystemInfoWidget` → `ConfigurationAppIntent`  [AMBIGUOUS]
  SystemInfoWidget/AppIntent.swift · relation: conceptually_related_to

## Knowledge Gaps
- **26 isolated node(s):** `rising`, `falling`, `stable`, `unavailable`, `systemPower` (+21 more)
  These have ≤1 connection - possible missing edges or undocumented components.
- **Thin community `Terminal Notebook Export`** (1 nodes): `Empty Terminal Notebook Export`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **What is the exact relationship between `SystemInfoWidget` and `ConfigurationAppIntent`?**
  _Edge tagged AMBIGUOUS (relation: conceptually_related_to) - confidence is low._
- **Why does `ContentView` connect `Content Dashboard UI` to `Dashboard Metrics Model`, `System Monitoring Engine`, `Dashboard Presentation Logic`?**
  _High betweenness centrality (0.216) - this node is a cross-community bridge._
- **Why does `SystemInfoViewModel` connect `System Monitoring Engine` to `Content Dashboard UI`, `Dashboard Metrics Model`, `History Storage Reports`, `Power Telemetry Parsing`, `Network Details Resolution`?**
  _High betweenness centrality (0.215) - this node is a cross-community bridge._
- **Why does `DashboardPresentationBuilder` connect `Dashboard Presentation Logic` to `Content Dashboard UI`, `Dashboard Metrics Model`, `History Storage Reports`, `Power Telemetry Parsing`?**
  _High betweenness centrality (0.146) - this node is a cross-community bridge._
- **What connects `rising`, `falling`, `stable` to the rest of the system?**
  _26 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `Content Dashboard UI` be split into smaller, more focused modules?**
  _Cohesion score 0.08 - nodes in this community are weakly interconnected._
- **Should `Dashboard Metrics Model` be split into smaller, more focused modules?**
  _Cohesion score 0.08 - nodes in this community are weakly interconnected._