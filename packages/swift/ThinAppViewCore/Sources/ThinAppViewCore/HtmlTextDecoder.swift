import Foundation

/// Decodes HTML entities and strips markup from plain-text fields (titles, summaries).
public enum HtmlTextDecoder {
  private static let namedEntities: [String: String] = [
    "amp": "&",
    "lt": "<",
    "gt": ">",
    "quot": "\"",
    "apos": "'",
    "nbsp": "\u{00A0}",
    "ndash": "–",
    "mdash": "—",
    "hellip": "…",
    "lsquo": "\u{2018}",
    "rsquo": "\u{2019}",
    "ldquo": "\u{201C}",
    "rdquo": "\u{201D}",
  ]

  public static func decodePlainText(_ raw: String) -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return trimmed }
    return decodeEntities(stripHtmlTags(trimmed))
  }

  private static func stripHtmlTags(_ text: String) -> String {
    guard text.contains("<") else { return text }
    return text.replacingOccurrences(
      of: "<[^>]+>",
      with: "",
      options: .regularExpression
    )
  }

  private static func decodeEntities(_ text: String) -> String {
    guard text.contains("&") else { return text }
    var out = ""
    var index = text.startIndex
    while index < text.endIndex {
      guard text[index] == "&" else {
        out.append(text[index])
        index = text.index(after: index)
        continue
      }
      if let (decoded, nextIndex) = decodeEntity(startingAt: index, in: text) {
        out.append(decoded)
        index = nextIndex
      } else {
        out.append(text[index])
        index = text.index(after: index)
      }
    }
    return out
  }

  private static func decodeEntity(
    startingAt start: String.Index,
    in text: String
  ) -> (String, String.Index)? {
    guard start < text.endIndex, text[start] == "&" else { return nil }
    let afterAmp = text.index(after: start)
    guard afterAmp < text.endIndex else { return nil }

    if text[afterAmp] == "#" {
      let afterHash = text.index(after: afterAmp)
      guard afterHash < text.endIndex else { return nil }
      if text[afterHash].lowercased() == "x" {
        return decodeNumericEntity(
          in: text,
          start: text.index(after: afterHash),
          radix: 16
        )
      }
      return decodeNumericEntity(in: text, start: afterHash, radix: 10)
    }

    let nameStart = afterAmp
    guard
      let semiIndex = text[nameStart...].firstIndex(of: ";"),
      semiIndex > nameStart
    else { return nil }

    let name = String(text[nameStart ..< semiIndex]).lowercased()
    guard let decoded = namedEntities[name] else { return nil }
    return (decoded, text.index(after: semiIndex))
  }

  private static func decodeNumericEntity(
    in text: String,
    start: String.Index,
    radix: Int
  ) -> (String, String.Index)? {
    guard start < text.endIndex else { return nil }
    var end = start
    while end < text.endIndex, text[end] != ";" {
      end = text.index(after: end)
    }
    guard end < text.endIndex, end > start else { return nil }
    let digits = String(text[start ..< end])
    guard let codePoint = Int(digits, radix: radix), let scalar = Unicode.Scalar(codePoint) else {
      return nil
    }
    return (String(Character(scalar)), text.index(after: end))
  }
}
