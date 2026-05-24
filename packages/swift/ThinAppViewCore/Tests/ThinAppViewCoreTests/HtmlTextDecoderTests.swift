import Testing

@testable import ThinAppViewCore

@Suite("HtmlTextDecoder")
struct HtmlTextDecoderTests {
  @Test("decodes decimal numeric entities")
  func decimalEntities() {
    let raw = "Hackers are learning to exploit chatbot &#8216;personalities&#8217;"
    #expect(
      HtmlTextDecoder.decodePlainText(raw)
        == "Hackers are learning to exploit chatbot ‘personalities’"
    )
  }

  @Test("decodes hex numeric entities")
  func hexEntities() {
    #expect(HtmlTextDecoder.decodePlainText("A&#x2014;B") == "A—B")
  }

  @Test("decodes named entities")
  func namedEntities() {
    #expect(HtmlTextDecoder.decodePlainText("Tom &amp; Jerry") == "Tom & Jerry")
  }

  @Test("strips HTML tags from plain text")
  func stripsTags() {
    #expect(HtmlTextDecoder.decodePlainText("<i>Hello</i> &amp; world") == "Hello & world")
  }

  @Test("leaves plain text unchanged")
  func plainText() {
    #expect(HtmlTextDecoder.decodePlainText("Already clean") == "Already clean")
  }
}
