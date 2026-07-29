import AppKit
import Charts
import CurrentCore
import IOKit.ps
import Observation
import SwiftUI

@MainActor
@Observable
final class UsageMetricsMonitor {
    private(set) var records: [DailyUsageRecord] = []
    private(set) var lastPersistenceError: String?

    private let worker: ContextWorkerClient
    private let historyStore: DailyUsageStore
    private let calendar: Calendar
    private let samplingPolicy: UsageSamplingPolicy
    private var aggregator = ProcessResourceAggregator()
    private var samplingTask: Task<Void, Never>?
    private var persistenceTask: Task<Void, Never>?
    private var lastResourcePersistedAt = Date.distantPast
    private var isLoaded = false
    private var pendingTranscriptionDates: [Date] = []

    init(
        worker: ContextWorkerClient,
        historyStore: DailyUsageStore = DailyUsageStore(),
        calendar: Calendar = .autoupdatingCurrent,
        samplingPolicy: UsageSamplingPolicy = .lowOverhead
    ) {
        self.worker = worker
        self.historyStore = historyStore
        self.calendar = calendar
        self.samplingPolicy = samplingPolicy
    }

    var today: DailyUsageRecord? {
        let id = DailyUsageAggregation.dayIdentifier(
            for: Date(),
            calendar: calendar
        )
        return records.first { $0.id == id }
    }

    func start() {
        guard samplingTask == nil else { return }
        samplingTask = Task { [weak self] in
            guard let self else { return }
            let now = Date()
            do {
                records = try await historyStore.load(
                    now: now,
                    calendar: calendar
                )
                lastPersistenceError = nil
            } catch {
                lastPersistenceError = error.localizedDescription
            }
            isLoaded = true
            let pendingDates = pendingTranscriptionDates
            pendingTranscriptionDates.removeAll()
            for date in pendingDates {
                records = DailyUsageAggregation
                    .recordingSuccessfulTranscription(
                        at: date,
                        in: records,
                        calendar: calendar
                    )
            }
            if let latestPendingDate = pendingDates.last {
                enqueuePersistence(records, at: latestPendingDate)
            }
            lastResourcePersistedAt = now
            while !Task.isCancelled {
                await sampleOnce()
                do {
                    try await Task.sleep(
                        for: .seconds(samplingPolicy.samplingInterval)
                    )
                } catch {
                    return
                }
            }
        }
    }

    func stop() async {
        let activeSamplingTask = samplingTask
        activeSamplingTask?.cancel()
        samplingTask = nil
        await activeSamplingTask?.value
        await persistenceTask?.value
        await persist(records, at: Date())
    }

    func recordSuccessfulTranscription(at date: Date) {
        guard isLoaded else {
            pendingTranscriptionDates.append(date)
            return
        }
        records = DailyUsageAggregation.recordingSuccessfulTranscription(
            at: date,
            in: records,
            calendar: calendar
        )
        records = DailyUsageAggregation.pruning(
            records,
            now: date,
            calendar: calendar
        )
        enqueuePersistence(records, at: date)
    }

    func records(forLastDays days: Int, now: Date = Date())
        -> [DailyUsageRecord] {
        DailyUsageAggregation.pruning(
            records,
            now: now,
            calendar: calendar,
            retentionDays: days
        )
    }

    private func sampleOnce() async {
        let now = Date()
        var processIdentifiers = [ProcessInfo.processInfo.processIdentifier]
        if let workerPID = worker.processIdentifier,
           !processIdentifiers.contains(workerPID) {
            processIdentifiers.append(workerPID)
        }
        let snapshots = await Task.detached(priority: .utility) {
            processIdentifiers.compactMap {
                ProcessResourceReader.snapshot(processIdentifier: $0)
            }
        }.value
        guard !Task.isCancelled,
              let sample = aggregator.sample(
                from: snapshots,
                at: now,
                maximumGap: samplingPolicy.samplingInterval * 2
              ) else { return }
        records = DailyUsageAggregation.adding(
            sample: sample,
            to: records,
            calendar: calendar
        )
        records = DailyUsageAggregation.pruning(
            records,
            now: now,
            calendar: calendar
        )
        if samplingPolicy.shouldPersist(
            lastPersistedAt: lastResourcePersistedAt,
            now: now
        ) {
            enqueuePersistence(records, at: now)
            lastResourcePersistedAt = now
        }
    }

    private func enqueuePersistence(
        _ snapshot: [DailyUsageRecord],
        at date: Date
    ) {
        let previous = persistenceTask
        let store = historyStore
        let calendar = calendar
        persistenceTask = Task { [weak self] in
            await previous?.value
            do {
                try await store.save(snapshot, now: date, calendar: calendar)
                self?.lastPersistenceError = nil
            } catch {
                self?.lastPersistenceError = error.localizedDescription
            }
        }
    }

    private func persist(
        _ snapshot: [DailyUsageRecord],
        at date: Date
    ) async {
        do {
            try await historyStore.save(
                snapshot,
                now: date,
                calendar: calendar
            )
            lastPersistenceError = nil
        } catch {
            lastPersistenceError = error.localizedDescription
        }
    }
}

@MainActor
final class UsageStatisticsWindowController: NSObject, NSWindowDelegate {
    private unowned let runtime: AppRuntime
    private let auxiliaryWindowID = UUID()
    private var window: NSWindow?
    private var viewModel: UsageStatisticsViewModel?

    init(runtime: AppRuntime) {
        self.runtime = runtime
        super.init()
    }

    func show() {
        if viewModel == nil {
            viewModel = UsageStatisticsViewModel(
                monitor: runtime.usageMonitor,
                contextDirectory: runtime.contextStore.directory
            )
        }
        viewModel?.activate()
        if window == nil, let viewModel {
            let controller = NSHostingController(
                rootView: UsageStatisticsView(model: viewModel)
            )
            let window = NSWindow(contentViewController: controller)
            window.title = "Usage Statistics"
            window.styleMask = [
                .titled,
                .closable,
                .resizable,
                .miniaturizable,
            ]
            window.titlebarAppearsTransparent = false
            window.titlebarSeparatorStyle = .none
            window.titleVisibility = .visible
            window.setContentSize(NSSize(width: 980, height: 700))
            window.minSize = NSSize(width: 760, height: 560)
            window.center()
            window.isReleasedWhenClosed = false
            window.delegate = self
            self.window = window
        }
        runtime.setAuxiliaryWindow(auxiliaryWindowID, visible: true)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        viewModel?.deactivate()
        runtime.setAuxiliaryWindow(auxiliaryWindowID, visible: false)
    }
}

private enum DailyHistoryRange: Int, CaseIterable, Identifiable {
    case sevenDays = 7
    case fourteenDays = 14
    case thirtyDays = 30

    var id: Int { rawValue }
    var title: String { "\(rawValue)d" }
}

@MainActor
@Observable
private final class UsageStatisticsViewModel {
    let monitor: UsageMetricsMonitor
    var selectedRange = DailyHistoryRange.sevenDays
    private(set) var battery = SystemBatteryReader.snapshot()
    private(set) var storage: StorageUsageSnapshot?
    private(set) var isRefreshingStorage = false

    private let calendar = Calendar.autoupdatingCurrent
    private let storageRoots: [StorageUsageCategory: [URL]]
    private var powerObserver: PowerSourceObserver?

    init(monitor: UsageMetricsMonitor, contextDirectory: URL) {
        self.monitor = monitor
        storageRoots = [
            .application: [Bundle.main.bundleURL],
            .speechModel: [ModelSnapshotLocations.current.snapshot],
            .contextModel: [GemmaModelLocations.current.snapshot],
            .contextLibrary: [contextDirectory],
            .otherUsageData: [DailyUsageStore.defaultDirectory()],
        ]
    }

    var visibleRecords: [DailyUsageRecord] {
        monitor.records(forLastDays: selectedRange.rawValue)
    }

    var chartDomain: ClosedRange<Date> {
        let today = calendar.startOfDay(for: Date())
        let start = calendar.date(
            byAdding: .day,
            value: -(selectedRange.rawValue - 1),
            to: today
        ) ?? today
        let end = calendar.date(byAdding: .day, value: 1, to: today) ?? Date()
        return start...end
    }

    func activate() {
        battery = SystemBatteryReader.snapshot()
        if powerObserver == nil {
            powerObserver = PowerSourceObserver { [weak self] in
                self?.battery = SystemBatteryReader.snapshot()
            }
        }
        refreshStorage()
    }

    func deactivate() {
        powerObserver = nil
    }

    func refreshStorage() {
        guard !isRefreshingStorage else { return }
        isRefreshingStorage = true
        let roots = storageRoots
        Task { [weak self] in
            let snapshot = await Task.detached(priority: .utility) {
                StorageUsageMeasurer.measure(roots: roots)
            }.value
            guard let self else { return }
            storage = snapshot
            isRefreshingStorage = false
        }
    }
}

private struct UsageStatisticsView: View {
    @Bindable var model: UsageStatisticsViewModel

    private let cardColumns = [
        GridItem(.adaptive(minimum: 150), spacing: 10),
    ]

    var body: some View {
        CurrentWindowBackground {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    overviewCards
                    historyToolbar
                    dailyCharts
                    if let error = model.monitor.lastPersistenceError {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(24)
            }
        }
    }

    private var overviewCards: some View {
        LazyVGrid(columns: cardColumns, spacing: 10) {
            metricCard(
                title: "Battery",
                value: batteryValue,
                detail: model.battery.statusDescription,
                symbol: batterySymbol
            )
            metricCard(
                title: "CPU",
                value: model.monitor.today?.averageCPUPercent.map {
                    String(format: "%.1f%%", $0)
                } ?? "Estimating…",
                detail: model.monitor.today.flatMap { record in
                    record.averageCPUPercent.map { _ in
                        "Peak \(String(format: "%.1f%%", record.cpuPeakPercent)) today"
                    }
                } ?? "Today’s average",
                symbol: "cpu"
            )
            metricCard(
                title: "Memory",
                value: model.monitor.today?.averageMemoryBytes.map {
                    formatBytes(Int64(clamping: $0))
                } ?? "Estimating…",
                detail: model.monitor.today.flatMap { record in
                    record.averageMemoryBytes.map { _ in
                        "Peak \(formatBytes(Int64(clamping: record.memoryPeakBytes))) today"
                    }
                } ?? "Today’s average",
                symbol: "memorychip"
            )
            metricCard(
                title: "Transcriptions",
                value: "\(model.monitor.today?.successfulTranscriptions ?? 0)",
                detail: "Successfully transcribed today",
                symbol: "text.bubble"
            )
            metricCard(
                title: "Total Storage",
                value: storageValue,
                detail: storageUpdatedText,
                symbol: "internaldrive",
                showsRefresh: true
            )
            ForEach(StorageUsageCategory.allCases) { category in
                metricCard(
                    title: category.displayName,
                    value: storageValue(for: category),
                    detail: "Stored on this Mac",
                    symbol: storageSymbol(for: category)
                )
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var historyToolbar: some View {
        HStack {
            Text("Daily averages")
                .font(.headline)
            Spacer()
            Picker("History", selection: $model.selectedRange) {
                ForEach(DailyHistoryRange.allCases) { range in
                    Text(range.title).tag(range)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 190)
            .accessibilityLabel("History range")
        }
    }

    private var dailyCharts: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 320), spacing: 16)],
            spacing: 16
        ) {
            chartCard(title: "CPU", valueLabel: "Daily average") {
                let records = model.visibleRecords.filter {
                    $0.averageCPUPercent != nil
                }
                if records.isEmpty {
                    chartEmptyState("Waiting for daily CPU estimates")
                } else {
                    Chart(records) { record in
                        if let average = record.averageCPUPercent {
                            LineMark(
                                x: .value("Day", record.day),
                                y: .value("CPU", average)
                            )
                            .foregroundStyle(.primary)
                            PointMark(
                                x: .value("Day", record.day),
                                y: .value("CPU", average)
                            )
                            .foregroundStyle(.primary)
                        }
                    }
                    .chartXScale(domain: model.chartDomain)
                    .chartYAxis {
                        AxisMarks(position: .leading) { value in
                            AxisGridLine()
                            AxisValueLabel {
                                if let percent = value.as(Double.self) {
                                    Text(
                                        "\(percent, format: .number.precision(.fractionLength(0)))%"
                                    )
                                }
                            }
                        }
                    }
                }
            }

            chartCard(title: "Memory", valueLabel: "Daily average") {
                let records = model.visibleRecords.filter {
                    $0.averageMemoryBytes != nil
                }
                if records.isEmpty {
                    chartEmptyState("Waiting for daily memory estimates")
                } else {
                    Chart(records) { record in
                        if let average = record.averageMemoryBytes {
                            LineMark(
                                x: .value("Day", record.day),
                                y: .value("Memory", Double(average))
                            )
                            .foregroundStyle(.primary)
                            PointMark(
                                x: .value("Day", record.day),
                                y: .value("Memory", Double(average))
                            )
                            .foregroundStyle(.primary)
                        }
                    }
                    .chartXScale(domain: model.chartDomain)
                    .chartYAxis {
                        AxisMarks(position: .leading) { value in
                            AxisGridLine()
                            AxisValueLabel {
                                if let bytes = value.as(Double.self) {
                                    Text(formatBytes(Int64(bytes)))
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func metricCard(
        title: String,
        value: String,
        detail: String,
        symbol: String,
        showsRefresh: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Label(title, systemImage: symbol)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                Spacer(minLength: 4)
                if showsRefresh {
                    Button {
                        model.refreshStorage()
                    } label: {
                        if model.isRefreshingStorage {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .buttonStyle(.borderless)
                    .disabled(model.isRefreshingStorage)
                    .help("Refresh storage usage")
                }
            }
            Text(value)
                .font(.system(size: 23, weight: .semibold, design: .rounded))
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .leading)
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(.separator.opacity(0.55), lineWidth: 0.5)
        }
        .accessibilityElement(children: .combine)
    }

    private func chartCard<Content: View>(
        title: String,
        valueLabel: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text("\(valueLabel) · Last \(model.selectedRange.title)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                content().frame(height: 230)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }

    private func chartEmptyState(_ message: String) -> some View {
        ContentUnavailableView(
            "No usage data yet",
            systemImage: "chart.xyaxis.line",
            description: Text(message)
        )
    }

    private var batteryValue: String {
        guard let level = model.battery.chargeLevel else { return "AC Power" }
        return level.formatted(.percent.precision(.fractionLength(0)))
    }

    private var batterySymbol: String {
        guard let level = model.battery.chargeLevel else { return "powerplug" }
        if model.battery.isCharging { return "battery.100percent.bolt" }
        switch level {
        case ..<0.15: return "battery.0percent"
        case ..<0.4: return "battery.25percent"
        case ..<0.65: return "battery.50percent"
        case ..<0.9: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    private var storageValue: String {
        model.storage.map { formatBytes($0.totalBytes) }
            ?? (model.isRefreshingStorage ? "Calculating…" : "Unavailable")
    }

    private var storageUpdatedText: String {
        guard let date = model.storage?.measuredAt else {
            return "Current-managed files"
        }
        return "Updated \(date.formatted(date: .omitted, time: .shortened))"
    }

    private func storageValue(for category: StorageUsageCategory) -> String {
        guard let storage = model.storage else {
            return model.isRefreshingStorage ? "Calculating…" : "Unavailable"
        }
        return formatBytes(storage.bytes(for: category))
    }

    private func storageSymbol(
        for category: StorageUsageCategory
    ) -> String {
        switch category {
        case .application: "app"
        case .speechModel: "waveform"
        case .contextModel: "brain"
        case .contextLibrary: "text.page"
        case .otherUsageData: "chart.xyaxis.line"
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

@MainActor
private final class PowerSourceObserver {
    private final class CallbackBox {
        let handler: @MainActor () -> Void

        init(handler: @escaping @MainActor () -> Void) {
            self.handler = handler
        }
    }

    private let callbackBox: CallbackBox
    nonisolated(unsafe) private var runLoopSource: CFRunLoopSource?

    init(handler: @escaping @MainActor () -> Void) {
        callbackBox = CallbackBox(handler: handler)
        let context = Unmanaged.passUnretained(callbackBox).toOpaque()
        guard let unmanagedSource = IOPSNotificationCreateRunLoopSource(
            { context in
                guard let context else { return }
                let box = Unmanaged<CallbackBox>
                    .fromOpaque(context)
                    .takeUnretainedValue()
                DispatchQueue.main.async { box.handler() }
            },
            context
        ) else { return }
        let source = unmanagedSource.takeRetainedValue()
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    }

    deinit {
        if let runLoopSource {
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(),
                runLoopSource,
                .commonModes
            )
        }
    }
}

private enum SystemBatteryReader {
    static func snapshot() -> BatterySnapshot {
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        guard let unmanagedInfo = IOPSCopyPowerSourcesInfo() else {
            return noBattery(lowPower: lowPower)
        }
        let info = unmanagedInfo.takeRetainedValue()
        guard let unmanagedSources = IOPSCopyPowerSourcesList(info) else {
            return noBattery(lowPower: lowPower)
        }
        let sources = unmanagedSources.takeRetainedValue() as [CFTypeRef]
        for source in sources {
            guard let unmanagedDescription = IOPSGetPowerSourceDescription(
                info,
                source
            ), let description = unmanagedDescription.takeUnretainedValue()
                as? [String: Any],
                description[kIOPSTypeKey] as? String
                    == kIOPSInternalBatteryType
            else { continue }
            let current = (description[kIOPSCurrentCapacityKey] as? NSNumber)?
                .doubleValue
            let maximum = (description[kIOPSMaxCapacityKey] as? NSNumber)?
                .doubleValue
            let level: Double? = if let current, let maximum, maximum > 0 {
                current / maximum
            } else {
                nil
            }
            let charging = (description[kIOPSIsChargingKey] as? NSNumber)?
                .boolValue ?? false
            let state = description[kIOPSPowerSourceStateKey] as? String
            return BatterySnapshot(
                chargeLevel: level,
                isCharging: charging,
                isOnACPower: state == kIOPSACPowerValue,
                isLowPowerModeEnabled: lowPower
            )
        }
        return noBattery(lowPower: lowPower)
    }

    private static func noBattery(lowPower: Bool) -> BatterySnapshot {
        BatterySnapshot(
            chargeLevel: nil,
            isCharging: false,
            isOnACPower: true,
            isLowPowerModeEnabled: lowPower
        )
    }
}
