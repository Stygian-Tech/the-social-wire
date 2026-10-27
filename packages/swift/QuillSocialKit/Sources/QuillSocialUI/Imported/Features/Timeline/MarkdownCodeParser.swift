#if os(iOS)
import Foundation

enum MarkdownCodeParser {
    static func segments(in text: String) -> [MarkdownTextSegment] {
        guard let expression = try? NSRegularExpression(
            pattern: #"(?ms)^```([A-Za-z0-9_+.-]*)[ \t]*\n(.*?)\n```[ \t]*(?=\n|$)"#
        ) else { return [MarkdownTextSegment(id: 0, byteStart: 0, kind: .prose(text))] }

        let matches = expression.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard !matches.isEmpty else {
            return [MarkdownTextSegment(id: 0, byteStart: 0, kind: .prose(text))]
        }

        var result: [MarkdownTextSegment] = []
        var cursor = text.startIndex
        for match in matches {
            guard let wholeRange = Range(match.range(at: 0), in: text),
                  let codeRange = Range(match.range(at: 2), in: text) else { continue }
            if cursor < wholeRange.lowerBound {
                let value = String(text[cursor..<wholeRange.lowerBound])
                result.append(.init(
                    id: result.count,
                    byteStart: text[..<cursor].utf8.count,
                    kind: .prose(value)
                ))
            }
            let language = Range(match.range(at: 1), in: text).map { String(text[$0]) }
            result.append(.init(
                id: result.count,
                byteStart: text[..<codeRange.lowerBound].utf8.count,
                kind: .code(
                    language: language?.isEmpty == false ? language : nil,
                    contents: String(text[codeRange])
                )
            ))
            cursor = wholeRange.upperBound
            if cursor < text.endIndex, text[cursor] == "\n" {
                cursor = text.index(after: cursor)
            }
        }
        if cursor < text.endIndex {
            result.append(.init(
                id: result.count,
                byteStart: text[..<cursor].utf8.count,
                kind: .prose(String(text[cursor...]))
            ))
        }
        return result
    }
}

#endif
