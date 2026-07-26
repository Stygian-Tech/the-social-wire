import Testing

@testable import OperationsCore

@Suite("BackfillRequestFingerprint")
struct BackfillRequestFingerprintTests {
  @Test("canonical request remains stable and order independent")
  func canonicalRequestIsStable() {
    let request = BackfillDryRunRequest(
      gapId: "gap-123",
      sourceMode: .jetstreamReplay,
      startCursor: 100,
      endCursor: 200,
      collections: ["site.standard.entry", "site.standard.document"],
      authorDids: ["did:plc:z", "did:plc:a"],
      batchSize: 1_000,
      rateLimit: 500,
      maxConcurrency: 1)

    #expect(
      BackfillRequestFingerprint.canonicalRequest(request)
        == "gap-123|jetstream_replay|100|200|site.standard.document,site.standard.entry|did:plc:a,did:plc:z|1000|500|1"
    )
  }
}
