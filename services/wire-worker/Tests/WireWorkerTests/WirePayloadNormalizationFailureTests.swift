import Testing
@testable import WireWorker

@Suite("The Wire ingestion payload normalization failures")
struct WirePayloadNormalizationFailureTests {
  @Test("recognizes only the staging fallback marker")
  func recognizesMarker() {
    #expect(PostgresWireInboxProcessor.isPayloadNormalizationFailure(
      #"{"$wireIngestionError":{"code":"payload_normalization_failed","version":1,"originalBytes":42}}"#
    ))
    #expect(!PostgresWireInboxProcessor.isPayloadNormalizationFailure(
      #"{"$wireIngestionError":{"code":"another_error","version":1}}"#
    ))
    #expect(!PostgresWireInboxProcessor.isPayloadNormalizationFailure(
      #"{"commit":{"record":{"text":"ordinary"}}}"#
    ))
  }
}
