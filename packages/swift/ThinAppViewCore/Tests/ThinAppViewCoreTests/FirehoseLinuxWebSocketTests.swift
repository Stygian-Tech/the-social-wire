#if canImport(WebSocketKit)
import Testing

@testable import ThinAppViewCore

@Suite("Linux firehose WebSocket")
struct FirehoseLinuxWebSocketTests {
  @Test("accepts ATProto records larger than WebSocketKit's default frame")
  func acceptsLargeFrames() {
    #expect(FirehoseLinuxWebSocket.maxFrameSize == 32 * 1_024 * 1_024)
  }
}
#endif
