import Foundation
import SwiftUI

enum HTMLRenderer {
    static func prepareArticleBody(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        if let repaired = repairedEscapedHtmlWrapper(trimmed) {
            return repaired
        }

        if !trimmed.contains("<") {
            return plainTextParagraphs(trimmed)
        }

        return trimmed
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
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src https: data:; style-src 'unsafe-inline'; font-src data:;">
        <style>
          :root { color-scheme: light dark; }
          body {
            font-family: -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif;
            font-size: 17px;
            color: \(palette.text);
            background: transparent;
            line-height: 1.58;
            padding: 0 18px 32px;
            margin: 0;
            overflow-wrap: break-word;
            -webkit-text-size-adjust: 100%;
          }
          h1, h2, h3, h4, h5, h6 { line-height: 1.2; color: \(palette.text); }
          p, li, span, div, td, th, blockquote, figcaption, label {
            color: \(palette.text);
          }
          a, a:visited { color: \(palette.link); }
          img, video { max-width: 100%; height: auto; border-radius: 8px; }
          pre, code, kbd, samp {
            font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
            background: \(palette.codeBackground);
            color: \(palette.text);
            border-radius: 6px;
          }
          pre {
            overflow-x: auto;
            white-space: pre-wrap;
            padding: 10px 12px;
          }
          code { padding: 0.1em 0.25em; }
          pre code { padding: 0; background: transparent; }
          blockquote {
            border-left: 3px solid \(palette.muted);
            margin-left: 0;
            padding-left: 14px;
            color: \(palette.muted);
          }
          table { border-collapse: collapse; width: 100%; }
          th, td { border: 1px solid \(palette.border); padding: 6px 8px; }
          hr { border: none; border-top: 1px solid \(palette.border); }
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
