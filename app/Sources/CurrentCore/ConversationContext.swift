import Foundation

public struct ConversationTurn: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let committedAt: Date
    public let instruction: String?
    public let committedText: String
    public let intent: VoiceIntent

    public init(
        id: UUID = UUID(),
        committedAt: Date = Date(),
        instruction: String?,
        committedText: String,
        intent: VoiceIntent
    ) {
        self.id = id
        self.committedAt = committedAt
        self.instruction = instruction?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.committedText = committedText.trimmingCharacters(in: .whitespacesAndNewlines)
        self.intent = intent
    }
}

public struct ConversationSnapshot: Codable, Sendable, Equatable {
    public let conversationID: UUID
    public let latestCommittedTexts: [ConversationTurn]
    public let rollingSummary: String
    public let olderTurns: [ConversationTurn]

    public init(
        conversationID: UUID,
        latestCommittedTexts: [ConversationTurn],
        rollingSummary: String,
        olderTurns: [ConversationTurn]
    ) {
        self.conversationID = conversationID
        self.latestCommittedTexts = latestCommittedTexts
        self.rollingSummary = rollingSummary
        self.olderTurns = olderTurns
    }
}

/// Canonical, process-lifetime conversation state. Model sessions are caches of
/// this state and can be discarded at any time without losing the conversation.
public actor ConversationContext {
    public static let recentTurnLimit = 10
    public static let summaryCharacterLimit = 6_000

    private var conversationID = UUID()
    private var turns: [ConversationTurn] = []

    public init() {}

    public func record(
        instruction: String?,
        committedText: String,
        intent: VoiceIntent,
        at date: Date = Date()
    ) {
        let turn = ConversationTurn(
            committedAt: date,
            instruction: instruction,
            committedText: committedText,
            intent: intent
        )
        guard !turn.committedText.isEmpty else { return }
        turns.append(turn)
    }

    public func snapshot() -> ConversationSnapshot {
        let split = max(0, turns.count - Self.recentTurnLimit)
        let older = Array(turns.prefix(split))
        return ConversationSnapshot(
            conversationID: conversationID,
            latestCommittedTexts: Array(turns.suffix(Self.recentTurnLimit)),
            rollingSummary: Self.summary(of: older),
            olderTurns: older
        )
    }

    public func clear() {
        turns.removeAll(keepingCapacity: false)
        conversationID = UUID()
    }

    public func count() -> Int { turns.count }

    private nonisolated static func summary(of turns: [ConversationTurn]) -> String {
        guard !turns.isEmpty else { return "" }
        var result = ""
        for turn in turns.reversed() {
            var line = "Committed: \(turn.committedText)"
            if let instruction = turn.instruction, !instruction.isEmpty {
                line = "Requested: \(instruction)\n\(line)"
            }
            let separator = result.isEmpty ? "" : "\n\n"
            guard separator.count + line.count + result.count <= summaryCharacterLimit else {
                break
            }
            result = line + separator + result
        }
        return result
    }
}
