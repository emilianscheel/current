import Foundation

public struct RecentApplicationLedger: Sendable {
    public struct Entry: Sendable, Equatable {
        public var target: ContextCaptureTarget
        public var lastActivity: Date
        public var nextEligibleAt: Date
        fileprivate var hasUrgentRefresh: Bool
        fileprivate var fairnessOrder: UInt64
    }

    public let policy: ContextBackgroundPolicy
    public private(set) var entries: [pid_t: Entry] = [:]
    public private(set) var lastJobCompletedAt: Date?
    private var nextFairnessOrder: UInt64 = 0

    public init(policy: ContextBackgroundPolicy = .init()) {
        self.policy = policy
    }

    @discardableResult
    public mutating func record(
        _ activity: RecentApplicationActivity
    ) -> Bool {
        guard !ContextApplicationExclusions.contains(
            processIdentifier: activity.target.processIdentifier,
            bundleIdentifier: activity.target.bundleIdentifier
        ) else {
            return false
        }
        expire(at: activity.occurredAt)
        let delay = activity.kind.isUrgent
            ? policy.urgentRefreshDelay
            : policy.normalRefreshDelay
        let proposedDue = activity.occurredAt.addingTimeInterval(delay)
        if var existing = entries[activity.target.processIdentifier] {
            existing.target = activity.target
            existing.lastActivity = activity.occurredAt
            if activity.kind.isUrgent {
                existing.nextEligibleAt = proposedDue
                existing.hasUrgentRefresh = true
            } else if !existing.hasUrgentRefresh {
                existing.nextEligibleAt = proposedDue
            }
            entries[activity.target.processIdentifier] = existing
        } else {
            entries[activity.target.processIdentifier] = Entry(
                target: activity.target,
                lastActivity: activity.occurredAt,
                nextEligibleAt: proposedDue,
                hasUrgentRefresh: activity.kind.isUrgent,
                fairnessOrder: nextFairnessOrder
            )
            nextFairnessOrder &+= 1
        }
        trimToCapacity()
        return entries[activity.target.processIdentifier] != nil
    }

    public mutating func expire(at now: Date) {
        entries = entries.filter {
            now.timeIntervalSince($0.value.lastActivity)
                < policy.recencyInterval
        }
    }

    public mutating func remove(processIdentifier: pid_t) {
        entries.removeValue(forKey: processIdentifier)
    }

    public mutating func nextEligible(at now: Date) -> Entry? {
        expire(at: now)
        guard globalSpacingDate <= now else { return nil }
        return entries.values
            .filter { $0.nextEligibleAt <= now }
            .min { lhs, rhs in
                if lhs.nextEligibleAt != rhs.nextEligibleAt {
                    return lhs.nextEligibleAt < rhs.nextEligibleAt
                }
                return lhs.fairnessOrder < rhs.fairnessOrder
            }
    }

    public mutating func markCompleted(
        processIdentifier: pid_t,
        at date: Date
    ) {
        lastJobCompletedAt = date
        guard var entry = entries[processIdentifier] else { return }
        guard date.timeIntervalSince(entry.lastActivity)
                < policy.recencyInterval else {
            entries.removeValue(forKey: processIdentifier)
            return
        }
        entry.nextEligibleAt = date.addingTimeInterval(
            policy.normalRefreshDelay
        )
        entry.hasUrgentRefresh = false
        entry.fairnessOrder = nextFairnessOrder
        nextFairnessOrder &+= 1
        entries[processIdentifier] = entry
    }

    public mutating func markDeferred(
        processIdentifier: pid_t,
        until date: Date
    ) {
        guard var entry = entries[processIdentifier] else { return }
        entry.nextEligibleAt = max(entry.nextEligibleAt, date)
        entries[processIdentifier] = entry
    }

    public mutating func nextWakeDate(at now: Date) -> Date? {
        expire(at: now)
        guard let applicationDate = entries.values
            .map(\.nextEligibleAt)
            .min() else {
            return nil
        }
        return max(applicationDate, globalSpacingDate)
    }

    private var globalSpacingDate: Date {
        lastJobCompletedAt?.addingTimeInterval(policy.interJobSpacing)
            ?? .distantPast
    }

    private mutating func trimToCapacity() {
        while entries.count > policy.maximumRecentApplications,
              let oldest = entries.min(by: {
                  $0.value.lastActivity < $1.value.lastActivity
              })?.key {
            entries.removeValue(forKey: oldest)
        }
    }
}
