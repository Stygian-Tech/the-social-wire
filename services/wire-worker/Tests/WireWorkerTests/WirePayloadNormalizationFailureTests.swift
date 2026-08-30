import Testing

@testable import WireWorkerCore

@Suite("The Wire ingestion payload normalization failures")
struct WirePayloadNormalizationFailureTests {
  @Test("recognizes only the staging fallback marker")
  func recognizesMarker() {
    #expect(
      PostgresWireInboxProcessor.isPayloadNormalizationFailure(
        #"{"$wireIngestionError":{"code":"payload_normalization_failed","version":1,"originalBytes":42}}"#
      ))
    #expect(
      !PostgresWireInboxProcessor.isPayloadNormalizationFailure(
        #"{"$wireIngestionError":{"code":"another_error","version":1}}"#
      ))
    #expect(
      !PostgresWireInboxProcessor.isPayloadNormalizationFailure(
        #"{"commit":{"record":{"text":"ordinary"}}}"#
      ))
  }
}

@Suite("The Wire publication dependency retry policy")
struct WirePublicationRetryPolicyTests {
  @Test("backs off unresolved publications without exceeding one hour")
  func boundedBackoff() {
    #expect(PostgresWireInboxProcessor.publicationRetryDelay(attemptCount: 1) == 300)
    #expect(PostgresWireInboxProcessor.publicationRetryDelay(attemptCount: 2) == 600)
    #expect(PostgresWireInboxProcessor.publicationRetryDelay(attemptCount: 5) == 3_600)
    #expect(PostgresWireInboxProcessor.publicationRetryDelay(attemptCount: 100) == 3_600)
  }

  @Test("transport identity does not include replay generation")
  func transportIdentity() {
    let key = PostgresWireInboxProcessor.transportEventKey(
      environment: "development",
      sourceHost: "jetstream.example",
      cursorKind: "jetstream_v2_seq",
      sequence: 24_924_930_989
    )
    #expect(key == "transport:development:jetstream.example:jetstream_v2_seq:24924930989")
  }
}
