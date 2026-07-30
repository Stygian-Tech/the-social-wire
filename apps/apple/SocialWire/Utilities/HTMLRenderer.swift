import Foundation
import SwiftUI

enum HTMLRenderer {
    static func prepareArticleBody(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let structured: String
        if let repaired = repairedEscapedHtmlWrapper(trimmed) {
            structured = repaired
        } else if !looksLikeHTML(trimmed) {
            structured = plainTextParagraphs(trimmed)
        } else {
            structured = trimmed
        }

        return linkifyBareURLs(
            normalizeMediaElements(
                normalizeLinkAttributes(
                    stripUnsafeMarkup(
                        replaceBlockedEmbeds(structured)
                    )
                )
            )
        )
    }

    static func wrappedHTML(_ html: String, colorScheme: ColorScheme) -> String {
        let body = prepareArticleBody(html)
        let palette = ReaderPalette(colorScheme: colorScheme)
        let darkOverrides = colorScheme == .dark
            ? """
          body, body *:not(a):not(img):not(video):not(svg):not(path) {
            color: \(palette.text) !important;
          }
          body a, body a * { color: \(palette.link) !important; }
          body pre, body code, body kbd, body samp {
            background: \(palette.codeBackground) !important;
          }
        """
            : ""

        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="color-scheme" content="light dark">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src https: data:; media-src https:; style-src 'unsafe-inline'; font-src data:;">
        <style>
          /* Mirrors the web `.article-content` reader treatment. */
          :root { color-scheme: light dark; }
          *, *::before, *::after { box-sizing: border-box; max-width: 100%; }
          body {
            font-family: system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", "Helvetica Neue", sans-serif;
            font-size: 16px;
            color: \(palette.text);
            background: transparent;
            line-height: 1.75;
            padding: 4px 16px 32px;
            margin: 0 auto;
            width: 100%;
            max-width: 72ch;
            overflow-wrap: anywhere;
            -webkit-text-size-adjust: 100%;
          }
          h1, h2, h3, h4, h5, h6 {
            color: \(palette.text);
            font-weight: 650;
            line-height: 1.25;
            margin: 1.6em 0 0.6em;
          }
          h1 { font-size: 1.875em; }
          h2 { font-size: 1.5em; }
          h3 { font-size: 1.25em; }
          h4, h5, h6 { font-size: 1.0625em; }
          h1:first-child, h2:first-child, h3:first-child,
          h4:first-child, h5:first-child, h6:first-child { margin-top: 0; }
          p, li, span, div, td, th, blockquote, figcaption, label {
            color: \(palette.text);
          }
          p, ul, ol, dl, blockquote, pre, table, figure, audio, video {
            margin: 0 0 1.15em;
          }
          ul, ol { padding-left: 1.6em; }
          li { margin: 0.3em 0; padding-left: 0.2em; }
          li > ul, li > ol { margin: 0.35em 0; }
          dt { font-weight: 650; }
          dd { margin: 0.25em 0 0.9em 1.25em; }
          a, a:visited {
            color: \(palette.link);
            text-decoration: underline;
            text-decoration-thickness: 0.1em;
            text-underline-offset: 0.22em;
          }
          img, video {
            display: block;
            width: auto;
            max-width: 100%;
            height: auto;
            border-radius: 10px;
            margin-inline: auto;
          }
          video, audio { width: 100%; }
          figure { margin-inline: 0; }
          figure > img, figure > video { margin-bottom: 0.5em; }
          figcaption, caption {
            font-size: 0.875em;
            line-height: 1.5;
            color: \(palette.muted);
            text-align: center;
          }
          pre, code, kbd, samp {
            font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
            background: \(palette.codeBackground);
            color: \(palette.text);
            border-radius: 6px;
            font-size: 0.875em;
          }
          pre {
            overflow-x: auto;
            white-space: pre;
            padding: 0.8em 1em;
            line-height: 1.6;
          }
          code { padding: 0.1em 0.3em; }
          pre code { padding: 0; background: transparent; font-size: 1em; }
          blockquote {
            border-left: 3px solid \(palette.link);
            padding-left: 1em;
            color: \(palette.muted);
            font-style: italic;
          }
          table {
            display: block;
            width: 100%;
            overflow-x: auto;
            border-collapse: collapse;
            font-size: 0.9em;
          }
          th, td {
            min-width: 8rem;
            border: 1px solid \(palette.border);
            padding: 0.5em 0.7em;
            text-align: left;
            vertical-align: top;
          }
          th { background: \(palette.codeBackground); font-weight: 650; }
          hr { border: none; border-top: 1px solid \(palette.border); margin: 1.75em 0; }
          .embedded-media-fallback {
            border: 1px solid \(palette.border);
            border-radius: 10px;
            background: \(palette.codeBackground);
            padding: 0.85em 1em;
            text-align: center;
          }
          body > :last-child { margin-bottom: 0; }
          \(darkOverrides)
        </style>
        </head>
        <body>\(body)</body>
        </html>
        """
    }

    private struct ReaderPalette {
        let text: String
        let link: String
        let muted: String
        let border: String
        let codeBackground: String

        init(colorScheme: ColorScheme) {
            switch colorScheme {
            case .dark:
                text = "#F5F5F7"
                link = "#6EB6FF"
                muted = "#98989D"
                border = "#3A3A3C"
                codeBackground = "#2C2C2E"
            default:
                text = "#1C1C1E"
                link = "#007AFF"
                muted = "#8E8E93"
                border = "#D1D1D6"
                codeBackground = "#F2F2F7"
            }
        }
    }

    private static func plainTextParagraphs(_ text: String) -> String {
        let paragraphs = text
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !paragraphs.isEmpty else { return "<p></p>" }
        return paragraphs
            .map { paragraph in
                let lines = paragraph
                    .components(separatedBy: "\n")
                    .map(escapeHtml)
                    .joined(separator: "<br>")
                return "<p>\(lines)</p>"
            }
            .joined()
    }

    private static func looksLikeHTML(_ text: String) -> Bool {
        text.range(of: #"<[a-zA-Z][^>]*>"#, options: .regularExpression) != nil
    }

    private static func replaceBlockedEmbeds(_ html: String) -> String {
        let containers = replacingMatches(
            in: html,
            pattern: #"<(?:iframe|object)\b[^>]*>[\s\S]*?</(?:iframe|object)\s*>"#
        ) { safeEmbeddedMediaLink(from: $0) }

        return replacingMatches(
            in: containers,
            pattern: #"<(?:iframe|embed|object)\b[^>]*\/?>"#
        ) { safeEmbeddedMediaLink(from: $0) }
    }

    private static func safeEmbeddedMediaLink(from tag: String) -> String {
        guard let rawSource = firstAttribute(named: "src", in: tag)
            ?? firstAttribute(named: "data", in: tag),
            let url = normalizedHTTPSURL(unescapeHtmlEntities(rawSource))
        else { return "" }

        return """
        <p class="embedded-media-fallback"><a href="\(escapeHtml(url))">Open Embedded Media</a></p>
        """
    }

    private static func stripUnsafeMarkup(_ html: String) -> String {
        let withoutContainers = html
            .replacingOccurrences(
                of: #"<(?:script|style)\b[^>]*>[\s\S]*?</(?:script|style)\s*>"#,
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
            .replacingOccurrences(
                of: #"<\/?(?:form|input|button|textarea|select|option)\b[^>]*>"#,
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
            .replacingOccurrences(
                of: #"<(?:object|embed)\b[^>]*\/?>"#,
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )

        return withoutContainers
            .replacingOccurrences(
                of: #"\s+on[a-z]+\s*=\s*(?:"[^"]*"|'[^']*'|[^\s>]+)"#,
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
            .replacingOccurrences(
                of: #"\s+style\s*=\s*(?:"[^"]*"|'[^']*'|[^\s>]+)"#,
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
    }

    private static func normalizeMediaElements(_ html: String) -> String {
        replacingMatches(in: html, pattern: #"<(?:audio|video|source)\b[^>]*>"#) { tag in
            let safeURLs = normalizeMediaURLAttributes(in: tag)
            guard safeURLs.range(
                of: #"^<\s*(?:audio|video)\b"#,
                options: [.regularExpression, .caseInsensitive]
            ) != nil else { return safeURLs }

            let cleaned = safeURLs
                .replacingOccurrences(
                    of: #"\s+autoplay(?:\s*=\s*(?:"[^"]*"|'[^']*'|[^\s>]+))?"#,
                    with: "",
                    options: [.regularExpression, .caseInsensitive]
                )
                .replacingOccurrences(
                    of: #"\s+controls(?:\s*=\s*(?:"[^"]*"|'[^']*'|[^\s>]+))?"#,
                    with: "",
                    options: [.regularExpression, .caseInsensitive]
                )
                .replacingOccurrences(
                    of: #"\s+preload(?:\s*=\s*(?:"[^"]*"|'[^']*'|[^\s>]+))?"#,
                    with: "",
                    options: [.regularExpression, .caseInsensitive]
                )
            return cleaned.dropLast() + #" controls preload="metadata">"#
        }
    }

    private static func normalizeLinkAttributes(_ html: String) -> String {
        replacingMatches(
            in: html,
            pattern: #"\s+href\s*=\s*(?:"[^"]*"|'[^']*'|[^\s>]+)"#
        ) { attribute in
            guard let rawValue = firstAttribute(named: "href", in: attribute) else { return "" }
            let decoded = unescapeHtmlEntities(rawValue)
            if let normalized = normalizedHTTPSURL(decoded) {
                return #" href="\#(escapeHtml(normalized))""#
            }
            let lowered = decoded.lowercased()
            if lowered.hasPrefix("mailto:") || decoded.hasPrefix("#") {
                return #" href="\#(escapeHtml(decoded))""#
            }
            return ""
        }
    }

    private static func normalizeMediaURLAttributes(in tag: String) -> String {
        replacingMatches(
            in: tag,
            pattern: #"\s+(?:src|poster)\s*=\s*(?:"[^"]*"|'[^']*'|[^\s>]+)"#
        ) { attribute in
            let name = attribute.range(
                of: #"\bsrc\b"#,
                options: [.regularExpression, .caseInsensitive]
            ) != nil ? "src" : "poster"
            guard let rawValue = firstAttribute(named: name, in: attribute),
                  let normalized = normalizedHTTPSURL(unescapeHtmlEntities(rawValue))
            else { return "" }
            return #" \#(name)="\#(escapeHtml(normalized))""#
        }
    }

    private static func linkifyBareURLs(_ html: String) -> String {
        guard let tagRegex = try? NSRegularExpression(pattern: #"<[^>]*>"#) else { return html }
        let fullRange = NSRange(html.startIndex..<html.endIndex, in: html)
        let matches = tagRegex.matches(in: html, range: fullRange)
        var output = ""
        var cursor = html.startIndex
        var protectedTags: [String] = []

        for match in matches {
            guard let range = Range(match.range, in: html) else { continue }
            let text = String(html[cursor..<range.lowerBound])
            output += protectedTags.isEmpty ? linkifyText(text) : text

            let tag = String(html[range])
            updateProtectedTags(&protectedTags, for: tag)
            output += tag
            cursor = range.upperBound
        }

        let remainder = String(html[cursor...])
        output += protectedTags.isEmpty ? linkifyText(remainder) : remainder
        return output
    }

    private static func updateProtectedTags(_ tags: inout [String], for rawTag: String) {
        let protectedNames = ["a", "code", "pre", "kbd", "samp"]
        for name in protectedNames {
            if rawTag.range(
                of: #"^<\s*/\s*\#(name)\b"#,
                options: [.regularExpression, .caseInsensitive]
            ) != nil {
                if let index = tags.lastIndex(of: name) {
                    tags.remove(at: index)
                }
                return
            }
            if rawTag.range(
                of: #"^<\s*\#(name)\b"#,
                options: [.regularExpression, .caseInsensitive]
            ) != nil, !rawTag.hasSuffix("/>") {
                tags.append(name)
                return
            }
        }
    }

    private static func linkifyText(_ text: String) -> String {
        replacingMatches(
            in: text,
            pattern: #"(?:https?://|www\.)[^\s<]+"#
        ) { match in
            let (url, trailing) = splitTrailingPunctuation(match)
            let href = url.lowercased().hasPrefix("www.") ? "https://\(url)" : url
            return #"<a href="\#(escapeHtml(href))">\#(url)</a>\#(trailing)"#
        }
    }

    private static func splitTrailingPunctuation(_ value: String) -> (String, String) {
        var url = value
        var trailing = ""
        while let last = url.last, ".,!?;:".contains(last) {
            trailing.insert(last, at: trailing.startIndex)
            url.removeLast()
        }
        while url.last == ")",
              url.filter({ $0 == ")" }).count > url.filter({ $0 == "(" }).count
        {
            trailing.insert(")", at: trailing.startIndex)
            url.removeLast()
        }
        return (url, trailing)
    }

    private static func replacingMatches(
        in value: String,
        pattern: String,
        transform: (String) -> String
    ) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive]
        ) else { return value }

        var result = value
        let fullRange = NSRange(value.startIndex..<value.endIndex, in: value)
        for match in regex.matches(in: value, range: fullRange).reversed() {
            guard let sourceRange = Range(match.range, in: value),
                  let resultRange = Range(match.range, in: result)
            else { continue }
            result.replaceSubrange(resultRange, with: transform(String(value[sourceRange])))
        }
        return result
    }

    private static func firstAttribute(named name: String, in tag: String) -> String? {
        guard let regex = try? NSRegularExpression(
            pattern: #"\b\#(name)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#,
            options: [.caseInsensitive]
        ) else { return nil }
        let range = NSRange(tag.startIndex..<tag.endIndex, in: tag)
        guard let match = regex.firstMatch(in: tag, range: range) else { return nil }
        for index in 1..<match.numberOfRanges where match.range(at: index).location != NSNotFound {
            guard let capture = Range(match.range(at: index), in: tag) else { continue }
            return String(tag[capture])
        }
        return nil
    }

    private static func normalizedHTTPSURL(_ raw: String) -> String? {
        guard var components = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return nil }
        components.scheme = "https"
        return components.url?.absoluteString
    }

    /// Repairs legacy RSS rows that stored HTML summaries as escaped markup inside a single `<p>`.
    private static func repairedEscapedHtmlWrapper(_ html: String) -> String? {
        guard html.hasPrefix("<p>"), html.hasSuffix("</p>") else { return nil }
        let innerStart = html.index(html.startIndex, offsetBy: 3)
        let innerEnd = html.index(html.endIndex, offsetBy: -4)
        guard innerStart < innerEnd else { return nil }
        let inner = String(html[innerStart ..< innerEnd])
        guard inner.contains("&lt;"), !inner.contains("<") else { return nil }
        return unescapeHtmlEntities(inner)
    }

    private static func escapeHtml(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func unescapeHtmlEntities(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}
