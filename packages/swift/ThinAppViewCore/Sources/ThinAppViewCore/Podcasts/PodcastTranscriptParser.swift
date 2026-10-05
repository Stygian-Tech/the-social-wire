import Foundation

public enum PodcastTranscriptParser {
  public static func parse(_ data: Data, type: String) -> (
    text: String, cues: [PodcastTranscriptCue]
  ) {
    let raw = String(decoding: data, as: UTF8.self)
    if type.contains("json"), let value = try? JSONSerialization.jsonObject(with: data) {
      let items =
        (value as? [[String: Any]]) ?? ((value as? [String: Any])?["segments"] as? [[String: Any]])
        ?? []
      let cues = items.compactMap { item -> PodcastTranscriptCue? in
        guard let text = item["text"] as? String,
          let start = (item["startTime"] ?? item["start"] ?? item["startSeconds"]) as? Double
        else { return nil }
        return PodcastTranscriptCue(
          startSeconds: start,
          endSeconds: (item["endTime"] ?? item["end"] ?? item["endSeconds"]) as? Double, text: text)
      }
      return (cues.map(\.text).joined(separator: "\n"), cues)
    }
    if type.contains("vtt") || type.contains("srt") || type.contains("subrip") {
      let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n")
      var cues: [PodcastTranscriptCue] = []
      for block in normalized.components(separatedBy: "\n\n") {
        let lines = block.components(separatedBy: "\n")
        guard let i = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
        let times = lines[i].components(separatedBy: "-->")
        guard times.count == 2, let start = time(times[0]), let end = time(times[1]) else {
          continue
        }
        let text = HtmlTextDecoder.decodePlainText(lines.dropFirst(i + 1).joined(separator: "\n"))
        if !text.isEmpty {
          cues.append(PodcastTranscriptCue(startSeconds: start, endSeconds: end, text: text))
        }
      }
      return (cues.map(\.text).joined(separator: "\n"), cues)
    }
    return (type.contains("html") ? HtmlTextDecoder.decodePlainText(raw) : raw, [])
  }
  private static func time(_ raw: String) -> Double? {
    let token =
      raw.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ").first ?? ""
    return PodcastRSSParser.duration(String(token).replacingOccurrences(of: ",", with: "."))
  }
}
