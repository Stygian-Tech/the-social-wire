import Foundation

public enum ProfileBioFacetDetector {
    public static func facets(in text: String) -> [TimelineFacet] {
        (mentions(in: text) + tags(in: text) + links(in: text)).sorted { $0.byteStart < $1.byteStart }
    }

    private static func mentions(in text: String) -> [TimelineFacet] {
        matches(
            pattern: #"(?<![A-Za-z0-9_])@([A-Za-z0-9](?:[A-Za-z0-9.-]{0,251}[A-Za-z0-9])?)"#,
            in: text
        ) { value in
            .mention(did: String(value.dropFirst()))
        }
    }

    private static func tags(in text: String) -> [TimelineFacet] {
        matches(
            pattern: #"(?<![\p{L}\p{M}\p{N}_])([#$][\p{L}\p{M}\p{N}_]+)"#,
            in: text
        ) { value in
            .tag(String(value.dropFirst()))
        }
    }

    private static func links(in text: String) -> [TimelineFacet] {
        matches(
            pattern: #"(?i)\bhttps?://[^\s<>()]+"#,
            in: text
        ) { value in
            .link(uri: String(value))
        }
    }

    private static func matches(
        pattern: String,
        in text: String,
        feature: (Substring) -> TimelineFacet.Feature
    ) -> [TimelineFacet] {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        return expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard let range = Range(match.range, in: text) else { return nil }
            return TimelineFacet(
                byteStart: text.utf8.distance(from: text.utf8.startIndex, to: range.lowerBound),
                byteEnd: text.utf8.distance(from: text.utf8.startIndex, to: range.upperBound),
                features: [feature(text[range])]
            )
        }
    }
}
