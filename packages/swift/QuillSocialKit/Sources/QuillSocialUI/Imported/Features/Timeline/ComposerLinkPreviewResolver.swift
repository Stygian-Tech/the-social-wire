#if os(iOS)
import Feeds
import Foundation

enum ComposerLinkPreviewResolver {
    nonisolated static func resolve(_ url: URL) async -> ComposerLinkPreview? {
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let httpResponse = response as? HTTPURLResponse,
              200..<300 ~= httpResponse.statusCode,
              let html = String(data: data, encoding: .utf8) else { return nil }

        let title = metaContent(named: "og:title", in: html)
            ?? capture(#"<title[^>]*>(.*?)</title>"#, in: html)
            ?? url.host()
            ?? url.absoluteString
        let description = metaContent(named: "og:description", in: html)
            ?? metaContent(named: "description", in: html)
            ?? ""
        let thumbnailURL = (metaContent(named: "og:image", in: html)
            ?? metaContent(named: "twitter:image", in: html))
            .flatMap { URL(string: $0, relativeTo: url)?.absoluteURL }
        let thumbnail: (data: Data, mimeType: String)?
        if let thumbnailURL {
            thumbnail = await loadThumbnail(from: thumbnailURL)
        } else {
            thumbnail = nil
        }

        return ComposerLinkPreview(
            embed: TimelineExternalEmbed(
                uri: url,
                title: decoded(title),
                description: decoded(description),
                thumbnailURL: thumbnailURL
            ),
            attachment: PostExternalAttachment(
                uri: url,
                title: decoded(title),
                description: decoded(description),
                thumbnailData: thumbnail?.data,
                thumbnailMimeType: thumbnail?.mimeType
            )
        )
    }

    private nonisolated static func loadThumbnail(from url: URL) async -> (data: Data, mimeType: String)? {
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              data.count <= 1_000_000,
              let httpResponse = response as? HTTPURLResponse,
              200..<300 ~= httpResponse.statusCode,
              let mimeType = httpResponse.mimeType,
              mimeType.hasPrefix("image/") else { return nil }
        return (data, mimeType)
    }

    private nonisolated static func metaContent(named name: String, in html: String) -> String? {
        tags(named: "meta", in: html).first { attributes in
            attributes["property"]?.caseInsensitiveCompare(name) == .orderedSame
                || attributes["name"]?.caseInsensitiveCompare(name) == .orderedSame
        }?["content"]
    }

    nonisolated static func tags(named name: String, in html: String) -> [[String: String]] {
        guard let tagExpression = try? NSRegularExpression(
            pattern: "<\(name)\\b[^>]*>",
            options: .caseInsensitive
        ), let attributeExpression = try? NSRegularExpression(
            pattern: #"([A-Za-z_:.-]+)\s*=\s*["']([^"']*)["']"#,
            options: .caseInsensitive
        ) else { return [] }

        return tagExpression.matches(in: html, range: NSRange(html.startIndex..., in: html)).map { match in
            guard let range = Range(match.range, in: html) else { return [:] }
            let tag = String(html[range])
            return Dictionary(attributeExpression.matches(
                in: tag,
                range: NSRange(tag.startIndex..., in: tag)
            ).compactMap { attribute in
                guard let keyRange = Range(attribute.range(at: 1), in: tag),
                      let valueRange = Range(attribute.range(at: 2), in: tag) else { return nil }
                return (String(tag[keyRange]).lowercased(), String(tag[valueRange]))
            }, uniquingKeysWith: { first, _ in first })
        }
    }

    private nonisolated static func capture(_ pattern: String, in value: String) -> String? {
        guard let expression = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ), let match = expression.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
           let range = Range(match.range(at: 1), in: value) else { return nil }
        return String(value[range]).replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
    }

    private nonisolated static func decoded(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

#endif
