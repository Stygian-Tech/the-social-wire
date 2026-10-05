import Foundation
import Testing
@testable import WireCorpusEdge

@Suite("Corpus sanitized failure diagnostics")
struct WireCorpusErrorDiagnosticsTests {
  @Test func excludesErrorDescriptionsAndRecordValues() {
    struct SensitiveFailure: Error, CustomStringConvertible {
      let description = "postgres://secret@host query='viewer draft'"
    }
    #expect(WireCorpusErrorDiagnostics.metadata(SensitiveFailure()) == ["category": "other"])
    let context = DecodingError.Context(codingPath: [], debugDescription: "private record value")
    #expect(WireCorpusErrorDiagnostics.metadata(DecodingError.dataCorrupted(context)) == ["category": "decode"])
    let encodingContext = EncodingError.Context(codingPath: [], debugDescription: "private record value")
    #expect(WireCorpusErrorDiagnostics.metadata(EncodingError.invalidValue("private draft", encodingContext)) == ["category": "encode"])
  }
}
