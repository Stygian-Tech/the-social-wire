#if os(iOS)
import ATProtoCore
import Feeds
import SwiftUI
import UIKit

struct RichPostTextView: View {
    let text: String
    let facets: [TimelineFacet]
    var textAlignment: TextAlignment = .leading

    @Environment(\.routeNavigator) private var navigator

    var body: some View {
        let displayFacets = CashtagTickerDetector.addingMissingFacets(in: text, to: facets)
        VStack(alignment: .leading, spacing: 6) {
            ForEach(MarkdownCodeParser.segments(in: text)) { segment in
                switch segment.kind {
                case .prose(let prose):
                    if !prose.isEmpty {
                        Text(attributedText(prose, byteStart: segment.byteStart, facets: displayFacets))
                            .frame(maxWidth: .infinity, alignment: frameAlignment)
                    }
                case .code(let language, let contents):
                    SyntaxHighlightedCodeView(
                        code: contents,
                        language: language,
                        showsLanguage: true
                    )
                }
            }
        }
            .foregroundStyle(.primary)
            .multilineTextAlignment(textAlignment)
            .frame(maxWidth: .infinity, alignment: frameAlignment)
            .environment(\.openURL, OpenURLAction { url in
                guard url.scheme == "quill" else {
                    return .systemAction
                }
                let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
                if url.host == "profile",
                   let did = items?.first(where: { $0.name == "did" })?.value,
                   let actor = try? ActorIdentifier(did) {
                    navigator?(.profile(actor))
                    return .handled
                }
                if url.host == "hashtag",
                   let topic = items?.first(where: { $0.name == "topic" })?.value {
                    navigator?(.hashtag(topic))
                    return .handled
                }
                return .systemAction
            })
    }

    private var frameAlignment: Alignment {
        switch textAlignment {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }

    private func attributedText(_ value: String, byteStart: Int, facets: [TimelineFacet]) -> AttributedString {
        var result = AttributedString(value)
        for facet in facets {
            guard let range = characterRange(for: facet, in: value, byteStart: byteStart),
                  let attributedRange = Range(range, in: result) else { continue }
            for feature in facet.features {
                switch feature {
                case let .mention(did):
                    var components = URLComponents()
                    components.scheme = "quill"
                    components.host = "profile"
                    components.queryItems = [URLQueryItem(name: "did", value: did)]
                    result[attributedRange].link = components.url
                    result[attributedRange].foregroundColor = .accentColor
                case let .link(uri):
                    result[attributedRange].link = URL(string: uri)
                    result[attributedRange].foregroundColor = .accentColor
                case let .tag(tag):
                    var components = URLComponents()
                    components.scheme = "quill"
                    components.host = "hashtag"
                    let renderedTag = String(value[range])
                    let topic = renderedTag.hasPrefix("$") && !tag.hasPrefix("$") ? "$\(tag)" : tag
                    components.queryItems = [URLQueryItem(name: "topic", value: topic)]
                    result[attributedRange].link = components.url
                    result[attributedRange].foregroundColor = .accentColor
                }
            }
        }
        styleInlineCode(in: &result, source: value)
        return result
    }

    private func characterRange(
        for facet: TimelineFacet,
        in value: String,
        byteStart: Int
    ) -> Range<String.Index>? {
        let localStart = facet.byteStart - byteStart
        let localEnd = facet.byteEnd - byteStart
        guard localStart >= 0, localEnd >= localStart,
              let utf8Start = value.utf8.index(value.utf8.startIndex, offsetBy: localStart, limitedBy: value.utf8.endIndex),
              let utf8End = value.utf8.index(value.utf8.startIndex, offsetBy: localEnd, limitedBy: value.utf8.endIndex),
              let start = String.Index(utf8Start, within: value),
              let end = String.Index(utf8End, within: value) else { return nil }
        return start..<end
    }

    private func styleInlineCode(in result: inout AttributedString, source: String) {
        guard let expression = try? NSRegularExpression(pattern: #"`([^`\n]+)`"#) else { return }
        for match in expression.matches(in: source, range: NSRange(source.startIndex..., in: source)).reversed() {
            guard let whole = Range(match.range(at: 0), in: source),
                  let contents = Range(match.range(at: 1), in: source),
                  let attributedWhole = Range(whole, in: result) else { continue }
            var replacement = AttributedString(String(source[contents]))
            let bodyPointSize = UIFont.preferredFont(forTextStyle: .body).pointSize
            replacement.font = Font(
                UIFont.monospacedSystemFont(ofSize: bodyPointSize, weight: .regular)
            )
            replacement.backgroundColor = .secondary.opacity(0.15)
            result.replaceSubrange(attributedWhole, with: replacement)
        }
    }
}

#endif
