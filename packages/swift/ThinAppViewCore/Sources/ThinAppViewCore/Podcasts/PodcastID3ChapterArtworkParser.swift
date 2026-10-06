import Foundation

/// Extracts raster pictures embedded in ID3v2.3/v2.4 CHAP frames, without decoding audio.
/// ID3 chapter layout: https://id3.org/id3v2-chapters-1.0
public enum PodcastID3ChapterArtworkParser {
  public static let maximumTagBytes = 4 * 1024 * 1024
  public static let maximumImageBytes = 1024 * 1024

  /// Complete prefix length, including the ten-byte ID3 header. Oversized/unsupported tags are ignored.
  public static func tagByteCount(header: Data) -> Int? {
    let bytes = Array(header.prefix(10))
    guard bytes.count == 10, bytes.prefix(3) == [73, 68, 51],
      [3, 4].contains(bytes[3]), bytes[4] != 255,
      bytes[5] & 0x80 == 0, // Whole-tag unsynchronisation is unsupported.
      bytes[5] & (bytes[3] == 3 ? 0x1f : 0x0f) == 0,
      let size = integer(bytes, at: 6, synchsafe: true),
      size > 0, size <= maximumTagBytes - 10 else { return nil }
    return size + 10
  }

  public static func parse(_ data: Data) -> [PodcastID3ChapterArtwork] {
    guard let count = tagByteCount(header: data), data.count >= count else { return [] }
    let bytes = Array(data.prefix(count))
    let version = bytes[3]
    var offset = 10
    if bytes[5] & 0x40 != 0 {
      guard let size = integer(bytes, at: offset, synchsafe: version == 4) else { return [] }
      let extendedSize = version == 3 ? size + 4 : size
      guard extendedSize >= (version == 3 ? 10 : 6), extendedSize <= count - offset else { return [] }
      offset += extendedSize
    }
    var output: [PodcastID3ChapterArtwork] = []
    var frames = 0
    while offset + 10 <= count, frames < 4096, output.count < 1000 {
      guard let frame = frame(bytes, at: offset, end: count, version: version) else { break }
      if frame.id == "CHAP", frame.supported,
        let artwork = chapter(bytes, range: frame.body, version: version) {
        output.append(artwork)
      }
      offset = frame.body.upperBound
      frames += 1
    }
    return output.sorted { $0.startSeconds < $1.startSeconds }
  }

  private static func integer(_ bytes: [UInt8], at offset: Int, synchsafe: Bool = false) -> Int? {
    guard offset >= 0, offset + 4 <= bytes.count else { return nil }
    let values = bytes[offset..<offset + 4]
    if synchsafe, values.contains(where: { $0 & 0x80 != 0 }) { return nil }
    return values.reduce(0) { ($0 << (synchsafe ? 7 : 8)) | Int($1) }
  }

  private static func frame(_ bytes: [UInt8], at offset: Int, end: Int, version: UInt8)
    -> (id: String, body: Range<Int>, supported: Bool)? {
    guard offset + 10 <= end else { return nil }
    let identifier = bytes[offset..<offset + 4]
    guard identifier.allSatisfy({ (65...90).contains($0) || (48...57).contains($0) }),
      let size = integer(bytes, at: offset + 4, synchsafe: version == 4),
      size > 0, size <= end - offset - 10 else { return nil }
    // Compression, encryption, grouping and frame unsynchronisation need separate decoding.
    return (String(decoding: identifier, as: UTF8.self), offset + 10..<offset + 10 + size, bytes[offset + 9] == 0)
  }

  private static func chapter(_ bytes: [UInt8], range: Range<Int>, version: UInt8) -> PodcastID3ChapterArtwork? {
    guard let terminator = bytes[range].prefix(1024).firstIndex(of: 0),
      terminator + 17 <= range.upperBound,
      let milliseconds = integer(bytes, at: terminator + 1), milliseconds != 0xffff_ffff else { return nil }
    var offset = terminator + 17
    var frames = 0
    while offset + 10 <= range.upperBound, frames < 256 {
      guard let frame = frame(bytes, at: offset, end: range.upperBound, version: version) else { return nil }
      if frame.id == "APIC", frame.supported, let picture = picture(bytes, range: frame.body) {
        return PodcastID3ChapterArtwork(startSeconds: Double(milliseconds) / 1000, data: picture.data, mimeType: picture.mimeType)
      }
      offset = frame.body.upperBound
      frames += 1
    }
    return nil
  }

  private static func picture(_ bytes: [UInt8], range: Range<Int>) -> (data: Data, mimeType: String)? {
    guard range.count >= 4, (0...3).contains(bytes[range.lowerBound]),
      let mimeEnd = bytes[(range.lowerBound + 1)..<range.upperBound].prefix(128).firstIndex(of: 0),
      mimeEnd + 2 < range.upperBound,
      String(decoding: bytes[(range.lowerBound + 1)..<mimeEnd], as: UTF8.self) != "-->" else { return nil }
    let encoding = bytes[range.lowerBound]
    var offset = mimeEnd + 2 // Skip MIME terminator and picture type.
    let limit = min(range.upperBound, offset + 1024)
    if encoding == 1 || encoding == 2 {
      while offset + 1 < limit, bytes[offset] != 0 || bytes[offset + 1] != 0 { offset += 2 }
      guard offset + 1 < limit else { return nil }
      offset += 2
    } else {
      guard let end = bytes[offset..<limit].firstIndex(of: 0) else { return nil }
      offset = end + 1
    }
    guard range.upperBound - offset <= maximumImageBytes, offset < range.upperBound else { return nil }
    let image = Data(bytes[offset..<range.upperBound])
    guard let mimeType = PodcastImage.mimeType(image) else { return nil }
    return (image, mimeType)
  }
}
