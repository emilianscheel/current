import Foundation

public enum MarkdownRichTextCodec {
    public static func attributedString(from markdown: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .full,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        guard let parsed = try? AttributedString(markdown: markdown, options: options) else {
            return AttributedString(markdown)
        }

        var output = AttributedString()
        var previousKey: Int?
        var previousStyle: BlockStyle?
        for run in parsed.runs {
            let key = blockIdentity(for: run.presentationIntent)
            let style = blockStyle(for: run.presentationIntent)
            if let previousKey, previousKey != key {
                let separator = previousStyle?.isList == true && style.isList ? "\n" : "\n\n"
                output.append(AttributedString(separator))
            }
            output.append(AttributedString(parsed[run.range]))
            previousKey = key
            previousStyle = style
        }
        return output
    }

    public static func markdown(from attributedString: AttributedString) -> String {
        guard !attributedString.characters.isEmpty else { return "" }
        var blocks: [Block] = []
        var current: Block?

        for run in attributedString.runs {
            let runText = String(attributedString[run.range].characters)
            if runText.allSatisfy(\.isNewline) {
                if let current { blocks.append(current) }
                current = nil
                continue
            }
            let style = blockStyle(for: run.presentationIntent)
            let key = blockIdentity(for: run.presentationIntent)
            let pieces = runText
                .split(separator: "\n", omittingEmptySubsequences: false)

            for (index, piece) in pieces.enumerated() {
                if current == nil || current?.key != key || current?.style != style {
                    if let current { blocks.append(current) }
                    current = Block(key: key, style: style, inline: "")
                }
                current?.inline += encodedInline(
                    String(piece),
                    intent: run.inlinePresentationIntent,
                    link: run.link
                )
                if index < pieces.count - 1 {
                    if let current { blocks.append(current) }
                    current = Block(key: UUID().hashValue, style: .paragraph, inline: "")
                }
            }
        }
        if let current { blocks.append(current) }

        var output: [String] = []
        var previousWasList = false
        for block in blocks {
            let line: String
            switch block.style {
            case .paragraph:
                line = block.inline
            case .heading(let level):
                line = String(repeating: "#", count: min(3, max(1, level))) + " " + block.inline
            case .unorderedList:
                line = "- " + block.inline
            case .orderedList(let ordinal):
                line = "\(max(1, ordinal)). " + block.inline
            case .quote:
                line = "> " + block.inline
            }

            let isList = block.style.isList
            if !output.isEmpty, !isList || !previousWasList {
                output.append("")
            }
            output.append(line)
            previousWasList = isList
        }
        return output.joined(separator: "\n").trimmingCharacters(in: .newlines) + "\n"
    }

    private struct Block {
        let key: Int
        let style: BlockStyle
        var inline: String
    }

    private enum BlockStyle: Equatable {
        case paragraph
        case heading(Int)
        case unorderedList
        case orderedList(Int)
        case quote

        var isList: Bool {
            switch self {
            case .unorderedList, .orderedList: true
            default: false
            }
        }
    }

    private static func blockIdentity(for intent: PresentationIntent?) -> Int {
        intent?.components.first?.identity ?? 0
    }

    private static func blockStyle(for intent: PresentationIntent?) -> BlockStyle {
        guard let components = intent?.components else { return .paragraph }
        for component in components {
            switch component.kind {
            case .header(let level): return .heading(level)
            case .unorderedList: return .unorderedList
            case .orderedList:
                let ordinal = components.compactMap { component -> Int? in
                    if case .listItem(let value) = component.kind { return value }
                    return nil
                }.first ?? 1
                return .orderedList(ordinal)
            case .blockQuote: return .quote
            default: continue
            }
        }
        return .paragraph
    }

    private static func encodedInline(
        _ text: String,
        intent: InlinePresentationIntent?,
        link: URL?
    ) -> String {
        var encoded = escapedInline(text)
        if intent?.contains(.code) == true {
            let fence = text.contains("`") ? "``" : "`"
            encoded = fence + text + fence
        } else {
            let bold = intent?.contains(.stronglyEmphasized) == true
            let italic = intent?.contains(.emphasized) == true
            if bold && italic { encoded = "***\(encoded)***" }
            else if bold { encoded = "**\(encoded)**" }
            else if italic { encoded = "*\(encoded)*" }
        }
        if let link {
            encoded = "[\(encoded)](\(link.absoluteString))"
        }
        return encoded
    }

    private static func escapedInline(_ text: String) -> String {
        var output = text.replacingOccurrences(of: "\\", with: "\\\\")
        for character in ["`", "*", "_", "[", "]"] {
            output = output.replacingOccurrences(of: character, with: "\\\(character)")
        }
        return output
    }
}
