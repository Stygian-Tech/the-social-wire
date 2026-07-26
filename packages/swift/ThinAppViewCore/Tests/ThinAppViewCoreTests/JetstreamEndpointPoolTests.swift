import Foundation
import OperationsCore
import Testing

@testable import ThinAppViewCore

@Suite("Jetstream endpoint failover")
struct JetstreamEndpointPoolTests {
  @Test("default configuration includes Jetstream 1 and Jetstream 2")
  func defaultEndpoints() {
    let config = ThinAppViewConfig.fromEnvironment([:])
    #expect(config.relayWebSocketURLs.count == 2)
    #expect(config.relayWebSocketURLs[0].contains("jetstream1.us-east.bsky.network"))
    #expect(config.relayWebSocketURLs[1].contains("jetstream2.us-east.bsky.network"))
  }

  @Test("legacy relay configuration keeps configured primary and adds fallbacks")
  func legacyPrimaryKeepsFallbacks() {
    let custom = "wss://custom.example/subscribe?wantedCollections=site.standard.document"
    let config = ThinAppViewConfig.fromEnvironment(["THIN_APPVIEW_RELAY_WS_URL": custom])
    #expect(config.relayWebSocketURLs.first == custom)
    #expect(config.relayWebSocketURLs.contains { $0.contains("jetstream1.us-east.bsky.network") })
    #expect(config.relayWebSocketURLs.contains { $0.contains("jetstream2.us-east.bsky.network") })
  }

  @Test("connection failure rotates one active endpoint without concurrent consumers")
  func rotatesAfterFailure() {
    var pool = JetstreamEndpointPool(urls: [
      "wss://jetstream1.us-east.bsky.network/subscribe",
      "wss://jetstream2.us-east.bsky.network/subscribe",
    ])
    #expect(pool.active.displayName == "Jetstream 1")
    #expect(pool.rotateAfterFailure().displayName == "Jetstream 2")
    #expect(pool.active.displayName == "Jetstream 2")
    #expect(pool.rotateAfterFailure().displayName == "Jetstream 1")
  }

  @Test("post-reconnect assessment only reports observed receive-to-commit backlog")
  func postReconnectGapAssessment() {
    let caughtUp = IngestionStreamState(
      environment: "test",
      source: "jetstream",
      connectionState: .connected,
      lastReceivedCursor: 2_000,
      lastCommittedCursor: 2_000,
      heartbeatAt: Date()
    )
    #expect(JetstreamGapDetector.postReconnectCandidate(state: caughtUp) == nil)

    let behind = IngestionStreamState(
      environment: "test",
      source: "jetstream",
      connectionState: .connected,
      lastReceivedCursor: 2_500,
      lastCommittedCursor: 2_000,
      heartbeatAt: Date()
    )
    let candidate = JetstreamGapDetector.postReconnectCandidate(state: behind)
    #expect(candidate?.startCursor == 2_000)
    #expect(candidate?.endCursor == 2_500)
    #expect(candidate?.reason == "operator_reconnect_receive_commit_backlog")
  }
}
