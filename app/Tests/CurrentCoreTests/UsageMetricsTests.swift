import Foundation
import Testing
@testable import CurrentCore

@Test func processResourceReaderCanInspectCurrentProcess() throws {
    let result = try #require(ProcessResourceReader.snapshot(
        processIdentifier: ProcessInfo.processInfo.processIdentifier
    ))
    #expect(result.physicalFootprintBytes > 0)
}

@Test func processResourceAggregationUsesActivityMonitorSemantics() throws {
    var aggregator = ProcessResourceAggregator()
    let start = Date(timeIntervalSince1970: 1_000)
    let firstValue = aggregator.sample(
        from: [
            snapshot(pid: 10, cpu: 1, memory: 100),
            snapshot(pid: 20, cpu: 2, memory: 200),
        ],
        at: start
    )
    let first = try #require(firstValue)
    #expect(first.cpuPercent == nil)
    #expect(first.memoryBytes == 300)

    let secondValue = aggregator.sample(
        from: [
            snapshot(pid: 10, cpu: 1.5, memory: 125),
            snapshot(pid: 20, cpu: 3, memory: 275),
        ],
        at: start.addingTimeInterval(1)
    )
    let second = try #require(secondValue)
    #expect(abs((second.cpuPercent ?? 0) - 150) < 0.001)
    #expect(second.memoryBytes == 400)
    #expect(second.continuityID == first.continuityID)
}

@Test func processResourceAggregationHandlesWorkerChangesAndGaps() throws {
    var aggregator = ProcessResourceAggregator()
    let start = Date(timeIntervalSince1970: 2_000)
    let firstValue = aggregator.sample(
        from: [snapshot(pid: 10, cpu: 1, memory: 100)],
        at: start
    )
    let first = try #require(firstValue)
    let workerStartedValue = aggregator.sample(
        from: [
            snapshot(pid: 10, cpu: 1.5, memory: 110),
            snapshot(pid: 20, cpu: 10, memory: 500),
        ],
        at: start.addingTimeInterval(1)
    )
    let workerStarted = try #require(workerStartedValue)
    #expect(abs((workerStarted.cpuPercent ?? 0) - 50) < 0.001)
    #expect(workerStarted.memoryBytes == 610)

    let afterGapValue = aggregator.sample(
        from: [snapshot(pid: 10, cpu: 2, memory: 120)],
        at: start.addingTimeInterval(30)
    )
    let afterGap = try #require(afterGapValue)
    #expect(afterGap.cpuPercent == nil)
    #expect(afterGap.continuityID != first.continuityID)
}

@Test func dailyUsageAggregationCalculatesAveragesPeaksAndCounts() throws {
    let calendar = utcCalendar()
    let day = try #require(calendar.date(
        from: DateComponents(year: 2026, month: 7, day: 29, hour: 8)
    ))
    let continuityID = UUID()
    var records: [DailyUsageRecord] = []
    records = DailyUsageAggregation.adding(
        sample: UsageSample(
            timestamp: day,
            cpuPercent: nil,
            memoryBytes: 100,
            continuityID: continuityID
        ),
        to: records,
        calendar: calendar
    )
    records = DailyUsageAggregation.adding(
        sample: UsageSample(
            timestamp: day.addingTimeInterval(900),
            cpuPercent: 50,
            memoryBytes: 300,
            continuityID: continuityID
        ),
        to: records,
        calendar: calendar
    )
    records = DailyUsageAggregation.adding(
        sample: UsageSample(
            timestamp: day.addingTimeInterval(1_800),
            cpuPercent: 150,
            memoryBytes: 500,
            continuityID: continuityID
        ),
        to: records,
        calendar: calendar
    )
    records = DailyUsageAggregation.recordingSuccessfulTranscription(
        at: day,
        in: records,
        calendar: calendar
    )
    let record = try #require(records.first)
    #expect(record.averageCPUPercent == 100)
    #expect(record.cpuPeakPercent == 150)
    #expect(record.averageMemoryBytes == 300)
    #expect(record.memoryPeakBytes == 500)
    #expect(record.successfulTranscriptions == 1)
}

@Test func dailyUsageAggregationUsesCalendarDayBoundaries() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
    let beforeMidnight = try #require(calendar.date(
        from: DateComponents(
            year: 2026,
            month: 7,
            day: 29,
            hour: 23,
            minute: 59
        )
    ))
    let afterMidnight = beforeMidnight.addingTimeInterval(120)
    var records: [DailyUsageRecord] = []
    for date in [beforeMidnight, afterMidnight] {
        records = DailyUsageAggregation.recordingSuccessfulTranscription(
            at: date,
            in: records,
            calendar: calendar
        )
    }
    #expect(records.count == 2)
    #expect(records.map(\.id) == ["2026-07-29", "2026-07-30"])
}

@Test func dailyUsageStorePersistsAndPrunesToThirtyDays() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = DailyUsageStore(directory: directory)
    let calendar = utcCalendar()
    let now = try #require(calendar.date(
        from: DateComponents(year: 2026, month: 7, day: 30, hour: 12)
    ))
    var records: [DailyUsageRecord] = []
    for offset in -35...0 {
        let date = try #require(calendar.date(
            byAdding: .day,
            value: offset,
            to: now
        ))
        records = DailyUsageAggregation.recordingSuccessfulTranscription(
            at: date,
            in: records,
            calendar: calendar
        )
    }
    try await store.save(records, now: now, calendar: calendar)
    let loaded = try await store.load(now: now, calendar: calendar)
    #expect(loaded.count == 30)
    #expect(loaded.first?.id == "2026-07-01")
    #expect(loaded.last?.successfulTranscriptions == 1)
}

@Test func dailyUsageStoreRecoversFromCorruptFile() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    let store = DailyUsageStore(directory: directory)
    try Data("not-json".utf8).write(to: await store.fileURL)
    let loaded = try await store.load(
        now: Date(),
        calendar: utcCalendar()
    )
    #expect(loaded.isEmpty)
    let rewritten = try Data(contentsOf: await store.fileURL)
    #expect(!rewritten.isEmpty)
}

@Test func dailyUsageStoreMigratesLegacySamplesWithoutCounts() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    let store = DailyUsageStore(directory: directory)
    let calendar = utcCalendar()
    let now = try #require(calendar.date(
        from: DateComponents(year: 2026, month: 7, day: 29, hour: 12)
    ))
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .millisecondsSince1970
    let samples = [
        UsageSample(
            timestamp: now.addingTimeInterval(-900),
            cpuPercent: 10,
            memoryBytes: 100,
            continuityID: UUID()
        ),
        UsageSample(
            timestamp: now,
            cpuPercent: 30,
            memoryBytes: 300,
            continuityID: UUID()
        ),
    ]
    var legacyData = Data()
    for sample in samples {
        legacyData.append(try encoder.encode(sample))
        legacyData.append(0x0A)
    }
    try legacyData.write(to: await store.legacyFileURL)

    let loaded = try await store.load(now: now, calendar: calendar)
    let record = try #require(loaded.first)
    #expect(record.averageCPUPercent == 20)
    #expect(record.averageMemoryBytes == 200)
    #expect(record.successfulTranscriptions == 0)
    #expect(!FileManager.default.fileExists(
        atPath: await store.legacyFileURL.path
    ))
    #expect(FileManager.default.fileExists(atPath: await store.fileURL.path))
}

@Test func transcriptionCountsPersistAcrossLoads() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = DailyUsageStore(directory: directory)
    let calendar = utcCalendar()
    let now = Date(timeIntervalSince1970: 10_000)
    var records: [DailyUsageRecord] = []
    records = DailyUsageAggregation.recordingSuccessfulTranscription(
        at: now,
        in: records,
        calendar: calendar
    )
    records = DailyUsageAggregation.recordingSuccessfulTranscription(
        at: now,
        in: records,
        calendar: calendar
    )
    try await store.save(records, now: now, calendar: calendar)
    let loaded = try await store.load(now: now, calendar: calendar)
    #expect(loaded.first?.successfulTranscriptions == 2)
}

@Test func lowOverheadSamplingPolicyUsesFifteenMinutesAndHourlyWrites() {
    let policy = UsageSamplingPolicy.lowOverhead
    #expect(policy.samplingInterval == 15 * 60)
    #expect(policy.persistenceInterval == 60 * 60)
    let start = Date(timeIntervalSince1970: 1_000)
    #expect(!policy.shouldPersist(
        lastPersistedAt: start,
        now: start.addingTimeInterval(3_599)
    ))
    #expect(policy.shouldPersist(
        lastPersistedAt: start,
        now: start.addingTimeInterval(3_600)
    ))
}

@Test func storageUsageMeasurerCategorizesFilesAndMissingRoots() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let app = directory.appendingPathComponent("App", isDirectory: true)
    let context = directory.appendingPathComponent(
        "Context",
        isDirectory: true
    )
    try FileManager.default.createDirectory(
        at: app,
        withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
        at: context,
        withIntermediateDirectories: true
    )
    try Data(repeating: 1, count: 32).write(
        to: app.appendingPathComponent("Current")
    )
    try Data(repeating: 2, count: 64).write(
        to: context.appendingPathComponent("Today.md")
    )
    let result = StorageUsageMeasurer.measure(roots: [
        .application: [app],
        .contextLibrary: [context],
        .speechModel: [directory.appendingPathComponent("Missing")],
    ])
    #expect(result.entries.count == StorageUsageCategory.allCases.count)
    #expect(result.bytes(for: .application) > 0)
    #expect(result.bytes(for: .contextLibrary) > 0)
    #expect(result.bytes(for: .speechModel) == 0)
}

@Test func batterySnapshotClampsLevelAndDescribesDesktopPower() {
    let battery = BatterySnapshot(
        chargeLevel: 1.5,
        isCharging: false,
        isOnACPower: false,
        isLowPowerModeEnabled: true
    )
    #expect(battery.chargeLevel == 1)
    #expect(battery.statusDescription == "On Battery · Low Power")
    let desktop = BatterySnapshot(
        chargeLevel: nil,
        isCharging: false,
        isOnACPower: true,
        isLowPowerModeEnabled: false
    )
    #expect(desktop.statusDescription == "AC Power · No battery")
}

private func snapshot(
    pid: pid_t,
    cpu: Double,
    memory: UInt64
) -> ProcessResourceSnapshot {
    ProcessResourceSnapshot(
        processIdentifier: pid,
        cpuTimeNanoseconds: UInt64(cpu * 1_000_000_000),
        physicalFootprintBytes: memory
    )
}

private func utcCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
}

private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString,
        isDirectory: true
    )
}
