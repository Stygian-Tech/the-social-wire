import Foundation

/// Extracts display candidates, not validated exchange listings, from post prose.
public enum CashtagTickerDetector {
    /// A ticker feed must represent exactly one cashtag, rather than a general search.
    public static func tickerTopic(in topic: String) -> String? {
        let topic = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidates = tickers(in: topic)
        guard candidates.count == 1, let ticker = candidates.first,
              topic.caseInsensitiveCompare("$\(ticker)") == .orderedSame else { return nil }
        return ticker
    }

    public static func tickers(in text: String, facets: [TimelineFacet] = []) -> [String] {
        var seen = Set<String>()
        return occurrences(in: text, facets: facets).compactMap { occurrence in
            seen.insert(occurrence.ticker).inserted ? occurrence.ticker : nil
        }
    }

    /// Supplies display links for posts whose authoring client omitted cashtag facets.
    /// Every occurrence is linked, while existing valid facets retain priority.
    public static func addingMissingFacets(in text: String, to facets: [TimelineFacet]) -> [TimelineFacet] {
        let occupiedRanges = facets.compactMap { characterRange(for: $0, in: text) }
        let additions = occurrences(in: text, facets: facets).compactMap { occurrence -> TimelineFacet? in
            guard !occupiedRanges.contains(where: {
                NSIntersectionRange($0, occurrence.range).length > 0
            }), let range = Range(occurrence.range, in: text) else { return nil }
            return TimelineFacet(
                byteStart: text[..<range.lowerBound].utf8.count,
                byteEnd: text[..<range.upperBound].utf8.count,
                features: [.tag("$\(occurrence.ticker)")]
            )
        }
        return (facets + additions).sorted { $0.byteStart < $1.byteStart }
    }

    private static func occurrences(in text: String, facets: [TimelineFacet]) -> [(ticker: String, range: NSRange)] {
        let exclusions = excludedRanges(in: text, facets: facets)
        let matches = matches(
            pattern: #"(?<![\p{L}\p{M}\p{N}_@$])\$([A-Za-z][A-Za-z0-9]{0,14}(?:\.[A-Za-z]{1,2})?)(?![\p{L}\p{M}\p{N}_]|\.[A-Za-z0-9])"#,
            in: text
        )
        return matches.compactMap { match in
            guard !exclusions.contains(where: { NSIntersectionRange($0, match.range).length > 0 }),
                  let range = Range(match.range(at: 1), in: text) else { return nil }
            let ticker = String(text[range]).uppercased()
            return (ticker, match.range)
        }
    }

    private static func excludedRanges(in text: String, facets: [TimelineFacet]) -> [NSRange] {
        var ranges = matches(
            pattern: #"(?i)(?:\b[a-z][a-z0-9+.-]*://|\bwww\.)[^\s<>]+|(?<![\p{L}\p{N}_])@[^\s<>]+"#,
            in: text
        ).map(\.range)
        let fences = fencedCodeRanges(in: text)
        ranges += fences
        // Parse inline spans only between fenced blocks so their delimiters cannot
        // accidentally pair with a different block and hide subsequent prose.
        var proseStart = 0
        for fence in fences + [NSRange(location: text.utf16.count, length: 0)] {
            ranges += matches(
                pattern: #"(?<!`)(`+)(?!`)[\s\S]*?(?<!`)\1(?!`)"#,
                in: text,
                range: NSRange(location: proseStart, length: fence.location - proseStart)
            ).map(\.range)
            proseStart = NSMaxRange(fence)
        }
        ranges += facets.compactMap { facet in
            guard facet.features.contains(where: { feature in
                switch feature {
                case .link, .mention: true
                case .tag: false
                }
            }) else { return nil }
            return characterRange(for: facet, in: text)
        }
        return ranges
    }

    private static func characterRange(for facet: TimelineFacet, in text: String) -> NSRange? {
        guard facet.byteStart >= 0, facet.byteEnd > facet.byteStart,
              facet.byteEnd <= text.utf8.count,
              let utf8Start = text.utf8.index(text.utf8.startIndex, offsetBy: facet.byteStart, limitedBy: text.utf8.endIndex),
              let utf8End = text.utf8.index(text.utf8.startIndex, offsetBy: facet.byteEnd, limitedBy: text.utf8.endIndex),
              let start = String.Index(utf8Start, within: text),
              let end = String.Index(utf8End, within: text) else { return nil }
        return NSRange(start..<end, in: text)
    }

    private static func fencedCodeRanges(in text: String) -> [NSRange] {
        let openings = matches(pattern: #"(?m)^[ \t]{0,3}(`{3,}|~{3,})[^\n]*(?:\n|\z)"#, in: text)
        var ranges: [NSRange] = []
        var cursor = 0
        for opening in openings {
            guard opening.range.location >= cursor,
                  let delimiterRange = Range(opening.range(at: 1), in: text),
                  let marker = text[delimiterRange].first else { continue }
            let length = text[delimiterRange].count
            let closingPattern = "(?m)^[ \\t]{0,3}\(marker){\(length),}[ \\t]*(?=\\r?\\n|\\z)"
            let remaining = NSRange(location: NSMaxRange(opening.range), length: text.utf16.count - NSMaxRange(opening.range))
            let closing = matches(pattern: closingPattern, in: text, range: remaining).first
            // A shorter or different delimiter does not close the fence. An
            // unfinished block remains excluded through the end of the post.
            cursor = closing.map { NSMaxRange($0.range) } ?? text.utf16.count
            ranges.append(NSRange(location: opening.range.location, length: cursor - opening.range.location))
        }
        return ranges
    }

    private static func matches(pattern: String, in text: String, range: NSRange? = nil) -> [NSTextCheckingResult] {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        return expression.matches(in: text, range: range ?? NSRange(text.startIndex..., in: text))
    }
}
