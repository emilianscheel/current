import Foundation

package enum RichTextListStyle: Equatable {
    case bulleted
    case numbered
}

package enum RichTextCharacterSelection {
    case insertionPoint(AttributedString.Index)
    case ranges([Range<AttributedString.Index>])
}

package enum RichTextListFormatter {
    package static func toggle(
        _ style: RichTextListStyle,
        in text: inout AttributedString,
        selection: RichTextCharacterSelection,
        identity: Int
    ) {
        let paragraphs = selectedParagraphRanges(in: text, selection: selection)
        guard !paragraphs.isEmpty else { return }
        let shouldRemove = paragraphs.allSatisfy { paragraph in
            listStyle(at: paragraph.lowerBound, in: text) == style
        }

        if shouldRemove {
            for (offset, paragraph) in paragraphs.enumerated() {
                text[paragraph].presentationIntent = PresentationIntent(
                    .paragraph,
                    identity: identity + offset
                )
            }
            return
        }

        let listKind: PresentationIntent.Kind = switch style {
        case .bulleted: .unorderedList
        case .numbered: .orderedList
        }
        let list = PresentationIntent(listKind, identity: identity)
        for (offset, paragraph) in paragraphs.enumerated() {
            let item = PresentationIntent(
                .listItem(ordinal: offset + 1),
                identity: identity + offset * 2 + 1,
                parent: list
            )
            text[paragraph].presentationIntent = PresentationIntent(
                .paragraph,
                identity: identity + offset * 2 + 2,
                parent: item
            )
        }
    }

    package static func selectedParagraphRanges(
        in text: AttributedString,
        selection: RichTextCharacterSelection
    ) -> [Range<AttributedString.Index>] {
        let paragraphs = paragraphRanges(in: text)
        switch selection {
        case .insertionPoint(let index):
            return paragraphs.filter { paragraph in
                paragraph.contains(index)
                    || index == paragraph.upperBound
                    || index == text.endIndex && paragraph.upperBound == text.endIndex
            }.suffix(1)
        case .ranges(let ranges):
            return paragraphs.filter { paragraph in
                ranges.contains { selection in
                    selection.lowerBound < paragraph.upperBound
                        && paragraph.lowerBound < selection.upperBound
                }
            }
        }
    }

    private static func paragraphRanges(
        in text: AttributedString
    ) -> [Range<AttributedString.Index>] {
        var result: [Range<AttributedString.Index>] = []
        var start = text.startIndex
        var index = start
        while index < text.endIndex {
            if text.characters[index] == "\n" {
                if start < index { result.append(start..<index) }
                start = text.characters.index(after: index)
            }
            index = text.characters.index(after: index)
        }
        if start < text.endIndex { result.append(start..<text.endIndex) }
        return result
    }

    private static func listStyle(
        at index: AttributedString.Index,
        in text: AttributedString
    ) -> RichTextListStyle? {
        guard index < text.endIndex else { return nil }
        for component in text[index..<text.characters.index(after: index)]
            .runs.first?.presentationIntent?.components ?? [] {
            switch component.kind {
            case .unorderedList: return .bulleted
            case .orderedList: return .numbered
            default: continue
            }
        }
        return nil
    }
}
