import Testing
@testable import WireWorker

@Suite("The Wire inbox processing policy")
struct WireInboxProcessingPolicyTests {
  @Test("claims never lease more events than the processor can run concurrently")
  func claimLimitTracksConcurrency() {
    #expect(
      PostgresWireInboxProcessor.boundedClaimLimit(
        batchSize: 5_000,
        maximumConcurrentEvents: 32
      ) == 32
    )
    #expect(
      PostgresWireInboxProcessor.boundedClaimLimit(
        batchSize: 16,
        maximumConcurrentEvents: 64
      ) == 16
    )
    #expect(
      PostgresWireInboxProcessor.boundedClaimLimit(
        batchSize: 10_000,
        maximumConcurrentEvents: 100
      ) == 64
    )
    #expect(
      PostgresWireInboxProcessor.boundedClaimLimit(
        batchSize: 0,
        maximumConcurrentEvents: 0
      ) == 1
    )
  }

  @Test("only unresolved passive Bluesky engagement is acknowledged without retry")
  func unresolvedReferencePolicy() {
    #expect(
      !PostgresWireInboxProcessor.retriesUnresolvedReference(
        collection: "app.bsky.feed.like"
      )
    )
    #expect(
      !PostgresWireInboxProcessor.retriesUnresolvedReference(
        collection: "app.bsky.feed.repost"
      )
    )
    #expect(
      PostgresWireInboxProcessor.retriesUnresolvedReference(
        collection: "site.standard.graph.recommend"
      )
    )
    #expect(
      PostgresWireInboxProcessor.retriesUnresolvedReference(
        collection: "app.thesocialwire.wireFeedback"
      )
    )
  }

  @Test("self follows are ignored before they reach the graph constraint")
  func selfFollowPolicy() {
    #expect(PostgresWireInboxProcessor.isSelfFollow(follower: "actor-a", followee: "actor-a"))
    #expect(!PostgresWireInboxProcessor.isSelfFollow(follower: "actor-a", followee: "actor-b"))
  }

  @Test("a post update that removes its article link retracts the prior signal")
  func linklessPostUpdatePolicy() {
    #expect(PostgresWireInboxProcessor.missingPostLinkRequiresRetraction(operation: "update"))
    #expect(!PostgresWireInboxProcessor.missingPostLinkRequiresRetraction(operation: "create"))
    #expect(!PostgresWireInboxProcessor.missingPostLinkRequiresRetraction(operation: "delete"))
    #expect(!PostgresWireInboxProcessor.missingPostLinkRequiresRetraction(operation: nil))
  }
}
