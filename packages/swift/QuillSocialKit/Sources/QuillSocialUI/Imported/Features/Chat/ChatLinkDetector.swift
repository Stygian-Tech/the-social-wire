#if os(iOS)
import ATProtoCore
import Foundation

struct ChatLinkDetector {
    struct Match: Sendable {
        let url: URL
        let range: Range<String.Index>
    }

    static func matches(in text: String, uniqueURLs: Bool = true) -> [Match] {
        guard let detector = try? NSDataDetector(
            types: NSTextCheckingResult.CheckingType.link.rawValue
        ) else { return [] }

        let fullRange = NSRange(text.startIndex..., in: text)
        var seen: Set<URL> = []
        return detector.matches(in: text, range: fullRange).compactMap { result in
            guard let url = result.url,
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https",
                  url.host() != nil,
                  (!uniqueURLs || seen.insert(url).inserted),
                  let range = Range(result.range, in: text)
            else { return nil }
            return Match(url: url, range: range)
        }
    }

    static func attributedText(_ text: String, facets: [ChatModels.Facet] = []) -> AttributedString {
        var attributedText = AttributedString(text)
        for match in matches(in: text, uniqueURLs: false) {
            guard let lowerBound = AttributedString.Index(match.range.lowerBound, within: attributedText),
                  let upperBound = AttributedString.Index(match.range.upperBound, within: attributedText)
            else { continue }
            attributedText[lowerBound..<upperBound].link = match.url
        }
        var occupied: [Range<String.Index>] = []
        for facet in facets {
            guard facet.index.byteStart >= 0, facet.index.byteEnd > facet.index.byteStart,
                  let utf8Start = text.utf8.index(text.utf8.startIndex, offsetBy: facet.index.byteStart, limitedBy: text.utf8.endIndex),
                  let utf8End = text.utf8.index(text.utf8.startIndex, offsetBy: facet.index.byteEnd, limitedBy: text.utf8.endIndex),
                  let start = String.Index(utf8Start, within: text),
                  let end = String.Index(utf8End, within: text) else { continue }
            let range = start..<end
            guard !occupied.contains(where: { $0.overlaps(range) }),
                  let attributedRange = Range(range, in: attributedText) else { continue }
            let url = facet.features.compactMap { feature -> URL? in
                switch feature.type {
                case "app.bsky.richtext.facet#mention":
                    guard let did = feature.did, (try? DID(did)) != nil else { return nil }
                    var components = URLComponents()
                    components.scheme = "quill"
                    components.host = "profile"
                    components.queryItems = [URLQueryItem(name: "did", value: did)]
                    return components.url
                case "app.bsky.richtext.facet#link":
                    guard let value = feature.uri, let url = URL(string: value),
                          ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host() != nil else { return nil }
                    return url
                default: return nil
                }
            }.first
            if let url {
                attributedText[attributedRange].link = url
                occupied.append(range)
            }
        }
        return attributedText
    }
}

#endif
