import Foundation

struct PostRichTextEncoder {
    struct Result {
        let text: String
        let facets: [Facet]
    }

    struct Facet: Encodable {
        let index: ByteSlice
        let features: [Feature]
    }

    struct ByteSlice: Encodable {
        let byteStart: Int
        let byteEnd: Int
    }

    enum Feature: Encodable {
        case mention(String)
        case link(String)
        case tag(String)

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .mention(let did):
                try container.encode("app.bsky.richtext.facet#mention", forKey: .type)
                try container.encode(did, forKey: .did)
            case .link(let uri):
                try container.encode("app.bsky.richtext.facet#link", forKey: .type)
                try container.encode(uri, forKey: .uri)
            case .tag(let tag):
                try container.encode("app.bsky.richtext.facet#tag", forKey: .type)
                try container.encode(tag, forKey: .tag)
            }
        }

        private enum CodingKeys: String, CodingKey {
            case type = "$type"
            case did, uri, tag
        }
    }

    static func encode(_ source: String, mentions: [String: String]) -> Result {
        let markdownExpression = try? NSRegularExpression(
            pattern: #"\[([^\]\n]+)\]\((https?://[^\s)]+)\)"#,
            options: [.caseInsensitive]
        )
        let matches = markdownExpression?.matches(
            in: source,
            range: NSRange(source.startIndex..., in: source)
        ) ?? []
        var text = ""
        var facets: [Facet] = []
        var cursor = source.startIndex

        for match in matches {
            guard let wholeRange = Range(match.range(at: 0), in: source),
                  let labelRange = Range(match.range(at: 1), in: source),
                  let uriRange = Range(match.range(at: 2), in: source) else { continue }
            text += source[cursor..<wholeRange.lowerBound]
            let label = String(source[labelRange])
            let byteStart = text.utf8.count
            text += label
            facets.append(Facet(
                index: ByteSlice(byteStart: byteStart, byteEnd: text.utf8.count),
                features: [.link(String(source[uriRange]))]
            ))
            cursor = wholeRange.upperBound
        }
        text += source[cursor...]

        for (handle, did) in mentions {
            appendOccurrences(
                of: "@\(handle)",
                in: text,
                feature: .mention(did),
                to: &facets
            )
        }
        appendMatches(
            pattern: #"https?://[^\s<>`]+"#,
            in: text,
            feature: { .link($0.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?)]}"))) },
            to: &facets
        )
        appendMatches(
            pattern: #"(?<![\p{L}\p{N}_])#([\p{L}\p{N}_]+)"#,
            in: text,
            feature: { .tag(String($0.dropFirst())) },
            to: &facets
        )
        appendMatches(
            pattern: #"(?<![\p{L}\p{N}_])\$([\p{L}][\p{L}\p{N}]{0,14}(?:\.[A-Za-z]{1,2})?)"#,
            in: text,
            feature: { .tag($0) },
            to: &facets
        )

        return Result(text: text, facets: facets.sorted { $0.index.byteStart < $1.index.byteStart })
    }

    private static func appendOccurrences(
        of value: String,
        in text: String,
        feature: Feature,
        to facets: inout [Facet]
    ) {
        var searchRange = text.startIndex..<text.endIndex
        while let range = text.range(of: value, options: [.caseInsensitive], range: searchRange) {
            let byteStart = text[..<range.lowerBound].utf8.count
            let byteEnd = text[..<range.upperBound].utf8.count
            if !facets.contains(where: { $0.index.byteStart < byteEnd && byteStart < $0.index.byteEnd }) {
                facets.append(Facet(
                    index: ByteSlice(byteStart: byteStart, byteEnd: byteEnd),
                    features: [feature]
                ))
            }
            searchRange = range.upperBound..<text.endIndex
        }
    }

    private static func appendMatches(
        pattern: String,
        in text: String,
        feature: (String) -> Feature,
        to facets: inout [Facet]
    ) {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return }
        for match in expression.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text) else { continue }
            let raw = String(text[range])
            let rendered = raw.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?)]}"))
            let byteStart = text[..<range.lowerBound].utf8.count
            let byteEnd = byteStart + rendered.utf8.count
            guard !facets.contains(where: { $0.index.byteStart < byteEnd && byteStart < $0.index.byteEnd }) else {
                continue
            }
            facets.append(Facet(
                index: ByteSlice(byteStart: byteStart, byteEnd: byteEnd),
                features: [feature(rendered)]
            ))
        }
    }
}
