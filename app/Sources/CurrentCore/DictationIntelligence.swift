import Foundation
import Observation
#if canImport(FoundationModels)
import FoundationModels
#endif

public enum DictationDestination: String, Codable, Sendable, CaseIterable {
    case message
    case emailOrDocument
    case codeOrTerminal
    case search
    case generic
}

public struct DictationContext: Codable, Sendable, Equatable {
    public static let maximumNearbyCharacters = 1_200
    public static let maximumSelectionCharacters = 6_000

    public var bundleIdentifier: String?
    public var applicationName: String?
    public var windowTitle: String?
    public var focusedRole: String?
    public var focusedSubrole: String?
    public var selectedText: String?
    public var textBeforeCursor: String
    public var textAfterCursor: String
    public var visibleIdentifiers: [String]
    public var destination: DictationDestination
    public var isSecure: Bool
    public var supportsSelectionEditing: Bool

    public init(
        bundleIdentifier: String? = nil,
        applicationName: String? = nil,
        windowTitle: String? = nil,
        focusedRole: String? = nil,
        focusedSubrole: String? = nil,
        selectedText: String? = nil,
        textBeforeCursor: String = "",
        textAfterCursor: String = "",
        visibleIdentifiers: [String] = [],
        destination: DictationDestination = .generic,
        isSecure: Bool = false,
        supportsSelectionEditing: Bool = false
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.applicationName = applicationName
        self.windowTitle = windowTitle
        self.focusedRole = focusedRole
        self.focusedSubrole = focusedSubrole
        self.selectedText = selectedText
        self.textBeforeCursor = String(textBeforeCursor.suffix(Self.maximumNearbyCharacters / 2))
        self.textAfterCursor = String(textAfterCursor.prefix(Self.maximumNearbyCharacters / 2))
        self.visibleIdentifiers = Array(visibleIdentifiers.prefix(80))
        self.destination = destination
        self.isSecure = isSecure
        self.supportsSelectionEditing = supportsSelectionEditing
    }

    public static let empty = DictationContext()

    public var isEditingSelection: Bool {
        supportsSelectionEditing
            && !(selectedText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    public var selectedWordCount: Int {
        selectedText?.split(whereSeparator: \.isWhitespace).count ?? 0
    }
}

public struct DictationRequest: Sendable {
    public let samples: [Float]
    public let context: DictationContext
    public let vocabulary: [LearnedVocabularyEntry]

    public init(
        samples: [Float],
        context: DictationContext,
        vocabulary: [LearnedVocabularyEntry] = []
    ) {
        self.samples = samples
        self.context = context
        self.vocabulary = vocabulary
    }
}

public enum AppliedTransformation: String, Codable, Sendable, CaseIterable {
    case learnedReplacement
    case contextualVocabulary
    case spokenPunctuation
    case fillerRemoval
    case repetitionRemoval
    case backtrack
    case listFormatting
    case contextualCasing
    case contextualPunctuation
    case foundationModel
    case selectionEdit
    case safetyFallback
}

public struct RefinementResult: Sendable, Equatable {
    public let text: String
    public let transformations: [AppliedTransformation]
    public let usedSafetyFallback: Bool

    public init(
        text: String,
        transformations: [AppliedTransformation] = [],
        usedSafetyFallback: Bool = false
    ) {
        self.text = text
        self.transformations = transformations
        self.usedSafetyFallback = usedSafetyFallback
    }
}

public struct TranscriptionCandidate: Sendable, Equatable {
    public let rawText: String
    public let refinedText: String
    public let transformations: [AppliedTransformation]
    public let usedSafetyFallback: Bool

    public init(rawText: String, refinement: RefinementResult) {
        self.rawText = rawText
        refinedText = refinement.text
        transformations = refinement.transformations
        usedSafetyFallback = refinement.usedSafetyFallback
    }
}

public struct LearnedVocabularyEntry: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public var spokenForm: String
    public var writtenForm: String
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        spokenForm: String,
        writtenForm: String,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.spokenForm = spokenForm
        self.writtenForm = writtenForm
        self.updatedAt = updatedAt
    }
}

@MainActor
@Observable
public final class LearnedVocabularyStore {
    private static let storageKey = "learnedVocabulary"
    private static let maximumEntries = 400
    private let defaults: UserDefaults
    public private(set) var entries: [LearnedVocabularyEntry]

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        entries = defaults.data(forKey: Self.storageKey)
            .flatMap { try? JSONDecoder().decode([LearnedVocabularyEntry].self, from: $0) }
            ?? []
    }

    public func learn(spokenForm: String, writtenForm: String) {
        let spoken = spokenForm.trimmingCharacters(in: .whitespacesAndNewlines)
        let written = writtenForm.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isSafeTerm(spoken), Self.isSafeTerm(written),
              spoken.compare(written, options: [.caseInsensitive, .diacriticInsensitive]) != .orderedSame else {
            return
        }
        entries.removeAll {
            $0.spokenForm.compare(spoken, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
        entries.insert(
            LearnedVocabularyEntry(spokenForm: spoken, writtenForm: written),
            at: 0
        )
        entries = Array(entries.prefix(Self.maximumEntries))
        save()
    }

    public func forgetAll() {
        entries = []
        defaults.removeObject(forKey: Self.storageKey)
    }

    private static func isSafeTerm(_ value: String) -> Bool {
        (1...80).contains(value.count)
            && !value.contains("\n")
            && value.rangeOfCharacter(from: .letters) != nil
    }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }
}

public enum DeterministicRefiner {
    private static let punctuationCommands: [(String, String)] = [
        (#"\b(?:new paragraph|start a new paragraph)\b"#, "\n\n"),
        (#"\b(?:new line|next line|line break)\b"#, "\n"),
        (#"\b(?:question mark)\b"#, "?"),
        (#"\b(?:exclamation (?:point|mark))\b"#, "!"),
        (#"\b(?:full stop|period)\b"#, "."),
        (#"\bsemicolon\b"#, ";"),
        (#"\bcolon\b"#, ":"),
        (#"\bcomma\b"#, ","),
        (#"\b(?:open parenthesis|open paren)\b"#, "("),
        (#"\b(?:close parenthesis|close paren)\b"#, ")"),
        (#"\b(?:double quote|quotation mark)\b"#, "\""),
        (#"\b(?:ampersand)\b"#, "&"),
        (#"\b(?:underscore)\b"#, "_"),
    ]

    public static func refine(
        _ rawText: String,
        context: DictationContext,
        vocabulary: [LearnedVocabularyEntry] = []
    ) -> RefinementResult {
        var text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        var applied: [AppliedTransformation] = []

        let learned = applyingLearnedVocabulary(text, entries: vocabulary)
        record(.learnedReplacement, changedFrom: text, to: learned, in: &applied)
        text = learned

        let contextual = applyingContextualIdentifiers(text, identifiers: context.visibleIdentifiers)
        record(.contextualVocabulary, changedFrom: text, to: contextual, in: &applied)
        text = contextual

        let punctuation = applyingSpokenPunctuation(text)
        record(.spokenPunctuation, changedFrom: text, to: punctuation, in: &applied)
        text = punctuation

        let withoutFillers = removingFillers(text)
        record(.fillerRemoval, changedFrom: text, to: withoutFillers, in: &applied)
        text = withoutFillers

        let withoutRepetitions = removingImmediateRepetitions(text)
        record(.repetitionRemoval, changedFrom: text, to: withoutRepetitions, in: &applied)
        text = withoutRepetitions

        let backtracked = applyingBacktrack(text)
        record(.backtrack, changedFrom: text, to: backtracked, in: &applied)
        text = backtracked

        let listed = formattingSimpleList(text)
        record(.listFormatting, changedFrom: text, to: listed, in: &applied)
        text = listed

        let cased = applyingContextualCasing(text, context: context)
        record(.contextualCasing, changedFrom: text, to: cased, in: &applied)
        text = cased

        let punctuated = applyingContextualPunctuation(text, context: context)
        record(.contextualPunctuation, changedFrom: text, to: punctuated, in: &applied)
        text = punctuated

        return RefinementResult(text: normalizedSpacing(text), transformations: applied)
    }

    private static func applyingLearnedVocabulary(
        _ text: String,
        entries: [LearnedVocabularyEntry]
    ) -> String {
        entries.reduce(text) { partial, entry in
            replacingLiteralPhrase(
                entry.spokenForm,
                with: entry.writtenForm,
                in: partial
            )
        }
    }

    private static func applyingContextualIdentifiers(
        _ text: String,
        identifiers: [String]
    ) -> String {
        identifiers.sorted { $0.count > $1.count }.reduce(text) { partial, identifier in
            let spoken = spokenForm(of: identifier)
            guard spoken.count >= 3 else { return partial }
            return replacingLiteralPhrase(spoken, with: identifier, in: partial)
        }
    }

    private static func spokenForm(of identifier: String) -> String {
        identifier
            .replacingOccurrences(
                of: #"([a-z0-9])([A-Z])"#,
                with: "$1 $2",
                options: .regularExpression
            )
            .replacingOccurrences(of: ".", with: " dot ")
            .replacingOccurrences(of: "_", with: " underscore ")
            .replacingOccurrences(of: "-", with: " dash ")
            .replacingOccurrences(
                of: #"[^A-Za-z0-9]+"#,
                with: " ",
                options: .regularExpression
            )
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .lowercased()
    }

    private static func applyingSpokenPunctuation(_ text: String) -> String {
        punctuationCommands.reduce(text) { partial, command in
            partial.replacingOccurrences(
                of: command.0,
                with: command.1,
                options: [.regularExpression, .caseInsensitive]
            )
        }
    }

    private static func removingFillers(_ text: String) -> String {
        text
            .replacingOccurrences(
                of: #"(?i)(^|(?<=[.!?]\s))(?:um+|uh+|erm+|hmm+|you know)(?:[,\s]+)"#,
                with: "",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"(?i)(?<=,\s)(?:um+|uh+|erm+|hmm+)(?:,\s|\s+)"#,
                with: "",
                options: .regularExpression
            )
    }

    private static func removingImmediateRepetitions(_ text: String) -> String {
        text.replacingOccurrences(
            of: #"(?i)\b([[:alnum:]']{2,})(?:\s+\1\b)+"#,
            with: "$1",
            options: .regularExpression
        )
    }

    private static func applyingBacktrack(_ text: String) -> String {
        var result = text
        result = result.replacingOccurrences(
            of: #"(?i)\b(Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday|January|February|March|April|May|June|July|August|September|October|November|December|\d+(?::\d+)?(?:\s*[ap]\.?m\.?)?)\s*,?\s*(?:actually|sorry|rather)\s*,?\s*(Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday|January|February|March|April|May|June|July|August|September|October|November|December|\d+(?::\d+)?(?:\s*[ap]\.?m\.?)?)\b"#,
            with: "$2",
            options: .regularExpression
        )
        if let range = result.range(
            of: #"(?i)(?:^|[.!?]\s+)[^.!?]*\b(?:scratch that|never mind)\b[,\s]*"#,
            options: .regularExpression
        ) {
            result.removeSubrange(range)
        }
        return result
    }

    private static func formattingSimpleList(_ text: String) -> String {
        guard let range = text.range(
            of: #"(?i)\b(?:are|following)\s+(?:one|1)[\s:,-]+(.+?)\s+(?:two|2)[\s:,-]+(.+?)(?:\s+(?:three|3)[\s:,-]+(.+))$"#,
            options: .regularExpression
        ) else { return text }
        let matched = String(text[range])
        guard let regex = try? NSRegularExpression(
            pattern: #"(?i)^(are|following)\s+(?:one|1)[\s:,-]+(.+?)\s+(?:two|2)[\s:,-]+(.+?)(?:\s+(?:three|3)[\s:,-]+(.+))?$"#
        ) else { return text }
        let nsRange = NSRange(matched.startIndex..<matched.endIndex, in: matched)
        guard let match = regex.firstMatch(in: matched, range: nsRange) else { return text }
        func capture(_ index: Int) -> String? {
            guard match.range(at: index).location != NSNotFound,
                  let range = Range(match.range(at: index), in: matched) else { return nil }
            return String(matched[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let lead = capture(1), let first = capture(2), let second = capture(3) else {
            return text
        }
        var replacement = "\(lead):\n1. \(capitalizingFirst(first))\n2. \(capitalizingFirst(second))"
        if let third = capture(4) {
            replacement += "\n3. \(capitalizingFirst(third))"
        }
        var result = text
        result.replaceSubrange(range, with: replacement)
        return result
    }

    private static func applyingContextualCasing(
        _ text: String,
        context: DictationContext
    ) -> String {
        guard !text.isEmpty else { return text }
        let continuesSentence = context.textBeforeCursor.last.map {
            !$0.isNewline && !".!?".contains($0)
        } ?? false
        if continuesSentence,
           let first = text.first,
           first.isUppercase,
           !startsWithVisibleProperNoun(text, identifiers: context.visibleIdentifiers) {
            return first.lowercased() + text.dropFirst()
        }
        guard !continuesSentence, let first = text.first, first.isLowercase else { return text }
        return first.uppercased() + text.dropFirst()
    }

    private static func applyingContextualPunctuation(
        _ text: String,
        context: DictationContext
    ) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        if context.destination == .message,
           trimmed.split(whereSeparator: \.isWhitespace).count <= 24,
           trimmed.hasSuffix(".") {
            return String(trimmed.dropLast())
        }
        return trimmed
    }

    private static func normalizedSpacing(_ text: String) -> String {
        text
            .replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #" +([,.;:!?])"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"([(\[])\s+"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"\s+([)\]])"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #" *\n *"#, with: "\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func replacingLiteralPhrase(
        _ phrase: String,
        with replacement: String,
        in text: String
    ) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: phrase)
            .replacingOccurrences(of: #"\ "#, with: #"\s+"#)
        return text.replacingOccurrences(
            of: #"(?i)(?<![\p{L}\p{N}])\#(escaped)(?![\p{L}\p{N}])"#,
            with: NSRegularExpression.escapedTemplate(for: replacement),
            options: .regularExpression
        )
    }

    private static func startsWithVisibleProperNoun(
        _ text: String,
        identifiers: [String]
    ) -> Bool {
        identifiers.contains {
            text.localizedCaseInsensitiveCompare($0) == .orderedSame
                || text.lowercased().hasPrefix($0.lowercased() + " ")
        }
    }

    private static func record(
        _ transformation: AppliedTransformation,
        changedFrom old: String,
        to new: String,
        in applied: inout [AppliedTransformation]
    ) {
        if old != new { applied.append(transformation) }
    }

    private static func capitalizingFirst(_ value: String) -> String {
        guard let first = value.first else { return value }
        return first.uppercased() + value.dropFirst()
    }
}

public enum SemanticSafetyGate {
    public static func accepts(candidate: String, preserving source: String) -> Bool {
        let source = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty, !candidate.isEmpty else { return source == candidate }
        let ratio = Double(candidate.count) / Double(max(1, source.count))
        guard (0.55...1.65).contains(ratio) else { return false }

        for pattern in protectedPatterns {
            guard captures(pattern, in: source) == captures(pattern, in: candidate) else {
                return false
            }
        }
        return true
    }

    private static let protectedPatterns = [
        #"\b\d+(?:[.,:]\d+)*(?:%|[aApP]\.?[mM]\.?)?\b"#,
        #"(?:https?://|www\.)[^\s]+"#,
        #"\b[A-Za-z][A-Za-z0-9_-]*\.(?:swift|ts|tsx|js|jsx|py|go|rs|json|md|ya?ml)\b"#,
        #"(?i)\b(?:not|no|never|without|isn't|aren't|don't|doesn't|won't|can't|cannot)\b"#,
        #""[^"]+""#,
        #"\b[A-Z]{2,8}\b"#,
        #"\b[A-Z][a-z]+(?:\s+[A-Z][a-z]+)*\b"#,
    ]

    private static func captures(_ pattern: String, in text: String) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return expression.matches(in: text, range: range).compactMap {
            Range($0.range, in: text).map { String(text[$0]).lowercased() }
        }
    }
}

public actor ContextualRefinementService {
#if canImport(FoundationModels)
    private var session: LanguageModelSession?
#endif

    public init() {}

    public func prewarm() {
#if canImport(FoundationModels)
        guard SystemLanguageModel.default.availability == .available else { return }
        let session = session ?? makeSession()
        self.session = session
        session.prewarm()
#endif
    }

    public func refine(
        deterministic: RefinementResult,
        rawText: String,
        context: DictationContext
    ) async -> RefinementResult {
        guard !deterministic.text.isEmpty else { return deterministic }
        guard !context.isSecure,
              context.destination != .codeOrTerminal,
              context.destination != .search,
              deterministic.text.split(whereSeparator: \.isWhitespace).count >= 6 else {
            return deterministic
        }
#if canImport(FoundationModels)
        guard SystemLanguageModel.default.availability == .available else {
            return deterministic
        }
        do {
            let session = session ?? makeSession()
            self.session = session
            let candidate = cleanedModelResponse(
                try await responseWithTimeout(
                    session: session,
                    prompt: prompt(
                    text: deterministic.text,
                    context: context
                    )
                )
            )
            guard SemanticSafetyGate.accepts(
                candidate: candidate,
                preserving: deterministic.text
            ) else {
                return RefinementResult(
                    text: deterministic.text,
                    transformations: deterministic.transformations + [.safetyFallback],
                    usedSafetyFallback: true
                )
            }
            guard candidate != deterministic.text else { return deterministic }
            return RefinementResult(
                text: candidate,
                transformations: deterministic.transformations + [.foundationModel]
            )
        } catch {
            session = nil
            return deterministic
        }
#else
        return deterministic
#endif
    }

    public func edit(
        selection: String,
        instruction: String,
        context: DictationContext
    ) async -> RefinementResult? {
        let direct = directEdit(
            selection: selection,
            instruction: instruction
        )
        if let direct {
            return RefinementResult(
                text: direct,
                transformations: [.selectionEdit]
            )
        }
#if canImport(FoundationModels)
        guard SystemLanguageModel.default.availability == .available else { return nil }
        do {
            let session = session ?? makeSession()
            self.session = session
            let candidate = cleanedModelResponse(
                try await responseWithTimeout(
                    session: session,
                    prompt: """
                Edit the selected text by following the spoken instruction.
                Return only the replacement text. Preserve facts, numbers, names, URLs, and filenames
                unless the instruction explicitly changes one of them.

                Selected text:
                \(selection)

                Spoken instruction:
                \(instruction)
                """
                )
            )
            guard !candidate.isEmpty else { return nil }
            return RefinementResult(
                text: candidate,
                transformations: [.selectionEdit, .foundationModel]
            )
        } catch {
            session = nil
            return nil
        }
#else
        return nil
#endif
    }

    private func directEdit(selection: String, instruction: String) -> String? {
        let normalized = instruction
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            .lowercased()
        switch normalized {
        case "delete", "delete that", "remove that":
            return ""
        case "uppercase", "make uppercase", "all caps":
            return selection.uppercased()
        case "lowercase", "make lowercase":
            return selection.lowercased()
        case "title case", "make title case":
            return selection.localizedCapitalized
        default:
            for prefix in ["replace with ", "change to ", "change it to "] where normalized.hasPrefix(prefix) {
                return String(
                    instruction.dropFirst(prefix.count)
                ).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let expression = try? NSRegularExpression(
                pattern: #"(?i)^(?:it'?s|spell(?: it)?|spelled?)\s+([A-Za-z](?:[\s-]+[A-Za-z]){1,})[.!]?$"#
            ) {
                let range = NSRange(
                    instruction.startIndex..<instruction.endIndex,
                    in: instruction
                )
                if let match = expression.firstMatch(in: instruction, range: range),
                   let lettersRange = Range(match.range(at: 1), in: instruction) {
                    let letters = instruction[lettersRange].filter(\.isLetter)
                    if selection.first?.isUppercase == true {
                        return letters.lowercased().capitalized
                    }
                    return letters.lowercased()
                }
            }
            if let expression = try? NSRegularExpression(
                pattern: #"(?i)^(?:change|replace)\s+(.+?)\s+(?:to|with)\s+(.+?)[.!]?$"#
            ) {
                let range = NSRange(
                    instruction.startIndex..<instruction.endIndex,
                    in: instruction
                )
                if let match = expression.firstMatch(in: instruction, range: range),
                   let oldRange = Range(match.range(at: 1), in: instruction),
                   let newRange = Range(match.range(at: 2), in: instruction) {
                    let old = String(instruction[oldRange])
                    let new = String(instruction[newRange])
                    let replaced = selection.replacingOccurrences(
                        of: old,
                        with: new,
                        options: .caseInsensitive
                    )
                    if replaced != selection { return replaced }
                }
            }
            return nil
        }
    }

#if canImport(FoundationModels)
    private func makeSession() -> LanguageModelSession {
        LanguageModelSession(
            instructions: """
            You refine speech-to-text locally. Return only the final text.
            Remove clear filler words and false starts, fix punctuation and capitalization, and
            format unmistakable lists. Never summarize, add information, change meaning, or answer
            the dictated text. Preserve all numbers, names, URLs, filenames, quoted text, and negation.
            Keep code, terminal commands, and search queries literal.
            """
        )
    }

    private func prompt(text: String, context: DictationContext) -> String {
        let before = String(context.textBeforeCursor.suffix(240))
        let after = String(context.textAfterCursor.prefix(160))
        return """
        Destination: \(context.destination.rawValue)
        Text immediately before cursor: \(before)
        Text immediately after cursor: \(after)

        Refine this dictated text and return only the refined text:
        \(text)
        """
    }

    private func responseWithTimeout(
        session: LanguageModelSession,
        prompt: String
    ) async throws -> String {
        let responseTask = Task {
            try await session.respond(to: prompt).content
        }
        let cancellationTask = Task {
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            responseTask.cancel()
        }
        defer { cancellationTask.cancel() }
        return try await responseTask.value
    }

    private func cleanedModelResponse(_ response: String) -> String {
        var value = response.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
            value.removeFirst()
            value.removeLast()
        }
        return value
    }
#endif
}
