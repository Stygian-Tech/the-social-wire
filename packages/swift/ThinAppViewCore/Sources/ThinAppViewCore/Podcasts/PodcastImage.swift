import Foundation

public enum PodcastImage {
  /// Raster formats only: no SVG/script content or publisher-controlled MIME forwarding.
  public static func mimeType(_ data: Data) -> String? {
    let bytes = Array(data.prefix(32))
    guard bytes.count >= 24 else { return nil }
    if bytes.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]),
      Array(bytes[12..<16]) == [73, 72, 68, 82] { return "image/png" }
    if bytes.starts(with: [255, 216, 255]), data.suffix(2) == Data([255, 217]) { return "image/jpeg" }
    if String(decoding: bytes.prefix(6), as: UTF8.self) == "GIF87a"
      || String(decoding: bytes.prefix(6), as: UTF8.self) == "GIF89a" { return "image/gif" }
    if String(decoding: bytes.prefix(4), as: UTF8.self) == "RIFF",
      String(decoding: bytes[8..<12], as: UTF8.self) == "WEBP" { return "image/webp" }
    if String(decoding: bytes[4..<8], as: UTF8.self) == "ftyp",
      ["avif", "avis"].contains(String(decoding: bytes[8..<12], as: UTF8.self)) { return "image/avif" }
    return nil
  }
}
