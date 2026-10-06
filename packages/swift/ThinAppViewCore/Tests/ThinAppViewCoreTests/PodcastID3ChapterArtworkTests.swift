import Foundation
import Testing
@testable import ThinAppViewCore

struct PodcastID3ChapterArtworkTests {
  private let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+j5X8AAAAASUVORK5CYII=")!

  private func integer(_ value: Int, synchsafe: Bool = false) -> [UInt8] {
    let shift = synchsafe ? 7 : 8
    let mask = synchsafe ? 127 : 255
    return (0..<4).reversed().map { UInt8((value >> ($0 * shift)) & mask) }
  }
  private func frame(_ id: String, _ body: [UInt8], version: UInt8, flags: UInt8 = 0) -> [UInt8] {
    Array(id.utf8) + integer(body.count, synchsafe: version == 4) + [0, flags] + body
  }
  private func chapter(_ milliseconds: Int, version: UInt8, encoding: UInt8 = 0, picture: Data? = nil,
    flags: UInt8 = 0) -> [UInt8] {
    let description: [UInt8] = encoding == 1 ? [255, 254, 65, 0, 0, 0] : [0]
    let apic = [encoding] + Array("image/png".utf8) + [0, 3] + description + Array(picture ?? png)
    let text = frame("TIT2", [0] + Array("Chapter".utf8), version: version)
    var body = Array("chapter\(milliseconds)".utf8)
    body.append(0)
    body.append(contentsOf: integer(milliseconds))
    body.append(contentsOf: integer(milliseconds + 1000))
    body.append(contentsOf: integer(0xffff_ffff))
    body.append(contentsOf: integer(0xffff_ffff))
    body.append(contentsOf: text)
    body.append(contentsOf: frame("APIC", apic, version: version, flags: flags))
    return frame("CHAP", body, version: version)
  }
  private func tag(_ body: [UInt8], version: UInt8 = 3, flags: UInt8 = 0) -> Data {
    Data([73, 68, 51, version, 0, flags] + integer(body.count, synchsafe: true) + body)
  }

  @Test func extractsSortedRasterChapterPicturesFromBothID3Versions() {
    for version: UInt8 in [3, 4] {
      let data = tag(chapter(2500, version: version) + chapter(0, version: version, encoding: 1), version: version)
      #expect(PodcastID3ChapterArtworkParser.tagByteCount(header: data.prefix(10)) == data.count)
      let values = PodcastID3ChapterArtworkParser.parse(data)
      #expect(values.map(\.startSeconds) == [0, 2.5])
      #expect(values.allSatisfy { $0.data == png && $0.mimeType == "image/png" })
    }
  }
  @Test func ignoresTopLevelCoverArtAndUnsupportedPictureFrames() {
    let cover = frame("APIC", [0] + Array("image/png".utf8) + [0, 3, 0] + Array(png), version: 3)
    let data = tag(cover + chapter(0, version: 3, flags: 0x80) + chapter(2000, version: 3))
    #expect(PodcastID3ChapterArtworkParser.parse(data).map(\.startSeconds) == [2])
  }
  @Test func rejectsTruncatedOversizedAndUnsupportedTags() {
    let data = tag(chapter(0, version: 3))
    #expect(PodcastID3ChapterArtworkParser.parse(data.dropLast()).isEmpty)
    #expect(PodcastID3ChapterArtworkParser.tagByteCount(header: tag([], version: 2)) == nil)
    #expect(PodcastID3ChapterArtworkParser.parse(tag(chapter(0, version: 3), flags: 0x80)).isEmpty)
    #expect(PodcastID3ChapterArtworkParser.tagByteCount(header: Data([73, 68, 51, 3, 0, 0] + integer(PodcastID3ChapterArtworkParser.maximumTagBytes, synchsafe: true))) == nil)
    #expect(PodcastID3ChapterArtworkParser.tagByteCount(header: Data([73, 68, 51, 3, 0, 0, 128, 0, 0, 0])) == nil)
  }
  @Test func rejectsNonRasterAndOversizedPicturePayloads() {
    #expect(PodcastID3ChapterArtworkParser.parse(tag(chapter(0, version: 3, picture: Data("<svg><script/></svg>".utf8)))).isEmpty)
    var oversized = png
    oversized.append(Data(repeating: 0, count: PodcastID3ChapterArtworkParser.maximumImageBytes))
    #expect(PodcastID3ChapterArtworkParser.parse(tag(chapter(0, version: 3, picture: oversized))).isEmpty)
  }
  @Test func skipsExtendedHeadersInBothVersions() {
    let v3 = integer(6) + [0, 0, 0, 0, 0, 0]
    let v4 = integer(6, synchsafe: true) + [1, 0]
    #expect(PodcastID3ChapterArtworkParser.parse(tag(v3 + chapter(0, version: 3), flags: 0x40)).count == 1)
    #expect(PodcastID3ChapterArtworkParser.parse(tag(v4 + chapter(0, version: 4), version: 4, flags: 0x40)).count == 1)
  }
  @Test func invalidFrameSizesAndMissingTerminatorsDoNotReadOutsideTheirFrame() {
    let invalid = Array("CHAP".utf8) + integer(1000) + [0, 0] + Array("unterminated".utf8)
    #expect(PodcastID3ChapterArtworkParser.parse(tag(invalid)).isEmpty)
    #expect(PodcastID3ChapterArtworkParser.parse(tag(frame("CHAP", [1, 2, 3], version: 3))).isEmpty)
    let noDescription = [0] + Array("image/png".utf8) + [0, 3] + Array(repeating: UInt8(1), count: 30)
    var body: [UInt8] = [0]
    body.append(contentsOf: integer(0))
    body.append(contentsOf: integer(1))
    body.append(contentsOf: integer(0))
    body.append(contentsOf: integer(0))
    body.append(contentsOf: frame("APIC", noDescription, version: 3))
    #expect(PodcastID3ChapterArtworkParser.parse(tag(frame("CHAP", body, version: 3))).isEmpty)
  }
}
