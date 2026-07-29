import Darwin
import Foundation

public struct UsageSample: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let timestamp: Date
    public let cpuPercent: Double?
    public let memoryBytes: UInt64
    public let continuityID: UUID

    public init(
        id: UUID = UUID(),
        timestamp: Date,
        cpuPercent: Double?,
        memoryBytes: UInt64,
        continuityID: UUID
    ) {
        self.id = id
        self.timestamp = timestamp
        self.cpuPercent = cpuPercent
        self.memoryBytes = memoryBytes
        self.continuityID = continuityID
    }
}

public struct DailyUsageRecord: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let day: Date
    public private(set) var cpuPercentTotal: Double
    public private(set) var cpuSampleCount: Int
    public private(set) var cpuPeakPercent: Double
    public private(set) var memoryBytesTotal: Double
    public private(set) var memorySampleCount: Int
    public private(set) var memoryPeakBytes: UInt64
    public private(set) var successfulTranscriptions: Int

    public init(
        id: String,
        day: Date,
        cpuPercentTotal: Double = 0,
        cpuSampleCount: Int = 0,
        cpuPeakPercent: Double = 0,
        memoryBytesTotal: Double = 0,
        memorySampleCount: Int = 0,
        memoryPeakBytes: UInt64 = 0,
        successfulTranscriptions: Int = 0
    ) {
        self.id = id
        self.day = day
        self.cpuPercentTotal = max(0, cpuPercentTotal)
        self.cpuSampleCount = max(0, cpuSampleCount)
        self.cpuPeakPercent = max(0, cpuPeakPercent)
        self.memoryBytesTotal = max(0, memoryBytesTotal)
        self.memorySampleCount = max(0, memorySampleCount)
        self.memoryPeakBytes = memoryPeakBytes
        self.successfulTranscriptions = max(0, successfulTranscriptions)
    }

    public var averageCPUPercent: Double? {
        guard cpuSampleCount > 0 else { return nil }
        return cpuPercentTotal / Double(cpuSampleCount)
    }

    public var averageMemoryBytes: UInt64? {
        guard memorySampleCount > 0 else { return nil }
        let average = memoryBytesTotal / Double(memorySampleCount)
        guard average < Double(UInt64.max) else { return UInt64.max }
        return UInt64(average)
    }

    public mutating func add(_ sample: UsageSample) {
        if let cpuPercent = sample.cpuPercent, cpuPercent.isFinite {
            cpuPercentTotal += max(0, cpuPercent)
            cpuSampleCount += 1
            cpuPeakPercent = max(cpuPeakPercent, cpuPercent)
        }
        memoryBytesTotal += Double(sample.memoryBytes)
        memorySampleCount += 1
        memoryPeakBytes = max(memoryPeakBytes, sample.memoryBytes)
    }

    public mutating func recordSuccessfulTranscription() {
        successfulTranscriptions += 1
    }
}

public enum DailyUsageAggregation {
    public static func dayIdentifier(
        for date: Date,
        calendar: Calendar
    ) -> String {
        let components = calendar.dateComponents(
            [.year, .month, .day],
            from: date
        )
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }

    public static func adding(
        sample: UsageSample,
        to records: [DailyUsageRecord],
        calendar: Calendar
    ) -> [DailyUsageRecord] {
        updating(records, at: sample.timestamp, calendar: calendar) {
            $0.add(sample)
        }
    }

    public static func recordingSuccessfulTranscription(
        at date: Date,
        in records: [DailyUsageRecord],
        calendar: Calendar
    ) -> [DailyUsageRecord] {
        updating(records, at: date, calendar: calendar) {
            $0.recordSuccessfulTranscription()
        }
    }

    public static func pruning(
        _ records: [DailyUsageRecord],
        now: Date,
        calendar: Calendar,
        retentionDays: Int = DailyUsageStore.retentionDays
    ) -> [DailyUsageRecord] {
        guard retentionDays > 0 else { return [] }
        let today = calendar.startOfDay(for: now)
        let cutoff = calendar.date(
            byAdding: .day,
            value: -(retentionDays - 1),
            to: today
        ) ?? today
        return records
            .filter { $0.day >= cutoff && $0.day <= today }
            .sorted { $0.day < $1.day }
    }

    private static func updating(
        _ records: [DailyUsageRecord],
        at date: Date,
        calendar: Calendar,
        update: (inout DailyUsageRecord) -> Void
    ) -> [DailyUsageRecord] {
        let id = dayIdentifier(for: date, calendar: calendar)
        var result = records
        if let index = result.firstIndex(where: { $0.id == id }) {
            update(&result[index])
        } else {
            var record = DailyUsageRecord(
                id: id,
                day: calendar.startOfDay(for: date)
            )
            update(&record)
            result.append(record)
        }
        return result.sorted { $0.day < $1.day }
    }
}

public actor DailyUsageStore {
    private struct FilePayload: Codable {
        let version: Int
        let records: [DailyUsageRecord]
    }

    public static let currentVersion = 1
    public static let retentionDays = 30

    public let directory: URL
    public let fileURL: URL
    public let legacyFileURL: URL
    private let fileManager: FileManager
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(
        directory: URL? = nil,
        fileManager: FileManager = .default
    ) {
        let resolvedDirectory = directory ?? Self.defaultDirectory(
            fileManager: fileManager
        )
        self.directory = resolvedDirectory
        fileURL = resolvedDirectory.appendingPathComponent("DailyUsage.json")
        legacyFileURL = resolvedDirectory.appendingPathComponent(
            "ResourceSamples.jsonl"
        )
        self.fileManager = fileManager
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        decoder.dateDecodingStrategy = .millisecondsSince1970
    }

    public static func defaultDirectory(
        fileManager: FileManager = .default
    ) -> URL {
        let support = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent(
            "Library/Application Support",
            isDirectory: true
        )
        return support.appendingPathComponent(
            "Current/Usage",
            isDirectory: true
        )
    }

    public func load(
        now: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent
    ) throws -> [DailyUsageRecord] {
        let records: [DailyUsageRecord]
        let migratedLegacyData: Bool
        if fileManager.fileExists(atPath: fileURL.path) {
            do {
                let payload = try decoder.decode(
                    FilePayload.self,
                    from: Data(contentsOf: fileURL)
                )
                records = payload.version == Self.currentVersion
                    ? payload.records : []
            } catch {
                records = []
            }
            migratedLegacyData = false
        } else {
            records = try migrateLegacySamples(calendar: calendar)
            migratedLegacyData = fileManager.fileExists(
                atPath: legacyFileURL.path
            )
        }
        let retained = DailyUsageAggregation.pruning(
            records,
            now: now,
            calendar: calendar
        )
        try save(retained, now: now, calendar: calendar)
        if migratedLegacyData {
            try? fileManager.removeItem(at: legacyFileURL)
        }
        return retained
    }

    public func save(
        _ records: [DailyUsageRecord],
        now: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent
    ) throws {
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let retained = DailyUsageAggregation.pruning(
            records,
            now: now,
            calendar: calendar
        )
        let payload = FilePayload(
            version: Self.currentVersion,
            records: retained
        )
        try encoder.encode(payload).write(to: fileURL, options: .atomic)
    }

    private func migrateLegacySamples(
        calendar: Calendar
    ) throws -> [DailyUsageRecord] {
        guard fileManager.fileExists(atPath: legacyFileURL.path) else {
            return []
        }
        let data = try Data(contentsOf: legacyFileURL)
        var seen: Set<UUID> = []
        var records: [DailyUsageRecord] = []
        for line in data.split(separator: 0x0A) {
            guard let sample = try? decoder.decode(
                UsageSample.self,
                from: Data(line)
            ), seen.insert(sample.id).inserted else { continue }
            records = DailyUsageAggregation.adding(
                sample: sample,
                to: records,
                calendar: calendar
            )
        }
        return records
    }
}

public struct UsageSamplingPolicy: Sendable, Equatable {
    public let samplingInterval: TimeInterval
    public let persistenceInterval: TimeInterval

    public static let lowOverhead = UsageSamplingPolicy(
        samplingInterval: 15 * 60,
        persistenceInterval: 60 * 60
    )

    public init(
        samplingInterval: TimeInterval,
        persistenceInterval: TimeInterval
    ) {
        self.samplingInterval = max(1, samplingInterval)
        self.persistenceInterval = max(1, persistenceInterval)
    }

    public func shouldPersist(lastPersistedAt: Date, now: Date) -> Bool {
        now.timeIntervalSince(lastPersistedAt) >= persistenceInterval
    }
}

public struct ProcessResourceSnapshot: Sendable, Equatable {
    public let processIdentifier: pid_t
    public let cpuTimeNanoseconds: UInt64
    public let physicalFootprintBytes: UInt64

    public init(
        processIdentifier: pid_t,
        cpuTimeNanoseconds: UInt64,
        physicalFootprintBytes: UInt64
    ) {
        self.processIdentifier = processIdentifier
        self.cpuTimeNanoseconds = cpuTimeNanoseconds
        self.physicalFootprintBytes = physicalFootprintBytes
    }
}

public struct ProcessResourceAggregator: Sendable {
    private var previous: [pid_t: ProcessResourceSnapshot] = [:]
    private var previousTimestamp: Date?
    private var continuityID = UUID()

    public init() {}

    public mutating func sample(
        from snapshots: [ProcessResourceSnapshot],
        at timestamp: Date,
        maximumGap: TimeInterval = 15
    ) -> UsageSample? {
        guard !snapshots.isEmpty else {
            previous = [:]
            previousTimestamp = nil
            continuityID = UUID()
            return nil
        }
        let current = Dictionary(
            uniqueKeysWithValues: snapshots.map {
                ($0.processIdentifier, $0)
            }
        )
        let memoryBytes = snapshots.reduce(UInt64(0)) {
            $0.addingReportingOverflow($1.physicalFootprintBytes).overflow
                ? UInt64.max : $0 + $1.physicalFootprintBytes
        }
        var cpuPercent: Double?
        if let previousTimestamp {
            let elapsed = timestamp.timeIntervalSince(previousTimestamp)
            if elapsed > 0, elapsed <= maximumGap {
                var cpuDelta: UInt64 = 0
                var hasComparableProcess = false
                for snapshot in snapshots {
                    guard let prior = previous[snapshot.processIdentifier],
                          snapshot.cpuTimeNanoseconds >= prior.cpuTimeNanoseconds
                    else { continue }
                    cpuDelta += snapshot.cpuTimeNanoseconds
                        - prior.cpuTimeNanoseconds
                    hasComparableProcess = true
                }
                if hasComparableProcess {
                    cpuPercent = max(
                        0,
                        Double(cpuDelta) / (elapsed * 1_000_000_000) * 100
                    )
                }
            } else {
                continuityID = UUID()
            }
        }
        previous = current
        previousTimestamp = timestamp
        return UsageSample(
            timestamp: timestamp,
            cpuPercent: cpuPercent,
            memoryBytes: memoryBytes,
            continuityID: continuityID
        )
    }
}

public enum ProcessResourceReader {
    public static func snapshot(
        processIdentifier: pid_t
    ) -> ProcessResourceSnapshot? {
        var usage = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(
                to: rusage_info_t?.self,
                capacity: 1
            ) { rebound in
                proc_pid_rusage(
                    processIdentifier,
                    RUSAGE_INFO_V4,
                    rebound
                )
            }
        }
        guard result == 0 else { return nil }
        return ProcessResourceSnapshot(
            processIdentifier: processIdentifier,
            cpuTimeNanoseconds: usage.ri_user_time + usage.ri_system_time,
            physicalFootprintBytes: usage.ri_phys_footprint
        )
    }
}

public enum StorageUsageCategory: String, Codable, CaseIterable, Sendable,
    Identifiable {
    case application
    case speechModel
    case contextModel
    case contextLibrary
    case otherUsageData

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .application: "Application"
        case .speechModel: "Speech Model"
        case .contextModel: "Context Model"
        case .contextLibrary: "Context Library"
        case .otherUsageData: "Other Usage Data"
        }
    }
}

public struct StorageUsageEntry: Sendable, Equatable, Identifiable {
    public let category: StorageUsageCategory
    public let bytes: Int64

    public init(category: StorageUsageCategory, bytes: Int64) {
        self.category = category
        self.bytes = max(0, bytes)
    }

    public var id: StorageUsageCategory { category }
}

public struct StorageUsageSnapshot: Sendable, Equatable {
    public let measuredAt: Date
    public let entries: [StorageUsageEntry]

    public init(measuredAt: Date, entries: [StorageUsageEntry]) {
        self.measuredAt = measuredAt
        self.entries = entries
    }

    public var totalBytes: Int64 {
        entries.reduce(0) { $0 + $1.bytes }
    }

    public func bytes(for category: StorageUsageCategory) -> Int64 {
        entries.first { $0.category == category }?.bytes ?? 0
    }
}

public enum StorageUsageMeasurer {
    public static func measure(
        roots: [StorageUsageCategory: [URL]],
        at date: Date = Date(),
        fileManager: FileManager = .default
    ) -> StorageUsageSnapshot {
        StorageUsageSnapshot(
            measuredAt: date,
            entries: StorageUsageCategory.allCases.map { category in
                StorageUsageEntry(
                    category: category,
                    bytes: roots[category, default: []].reduce(0) {
                        $0 + size(of: $1, fileManager: fileManager)
                    }
                )
            }
        )
    }

    public static func size(
        of url: URL,
        fileManager: FileManager = .default
    ) -> Int64 {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(
            atPath: url.path,
            isDirectory: &isDirectory
        ) else { return 0 }
        if !isDirectory.boolValue {
            return (try? url.resourceValues(forKeys: [.fileSizeKey]))?
                .fileSize.map(Int64.init) ?? 0
        }
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [
                .isRegularFileKey,
                .fileAllocatedSizeKey,
                .fileSizeKey,
            ],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [
                .isRegularFileKey,
                .fileAllocatedSizeKey,
                .fileSizeKey,
            ]), values.isRegularFile == true else { continue }
            total += Int64(values.fileAllocatedSize ?? values.fileSize ?? 0)
        }
        return total
    }
}

public struct BatterySnapshot: Sendable, Equatable {
    public let chargeLevel: Double?
    public let isCharging: Bool
    public let isOnACPower: Bool
    public let isLowPowerModeEnabled: Bool

    public init(
        chargeLevel: Double?,
        isCharging: Bool,
        isOnACPower: Bool,
        isLowPowerModeEnabled: Bool
    ) {
        self.chargeLevel = chargeLevel.map { min(1, max(0, $0)) }
        self.isCharging = isCharging
        self.isOnACPower = isOnACPower
        self.isLowPowerModeEnabled = isLowPowerModeEnabled
    }

    public var statusDescription: String {
        if chargeLevel == nil { return "AC Power · No battery" }
        if isCharging { return "Charging" }
        if isOnACPower { return "Power Adapter" }
        return isLowPowerModeEnabled ? "On Battery · Low Power" : "On Battery"
    }
}
