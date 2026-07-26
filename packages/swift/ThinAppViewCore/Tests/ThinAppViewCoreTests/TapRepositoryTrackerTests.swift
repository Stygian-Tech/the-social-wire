import AsyncHTTPClient
import Foundation
import Logging
import NIOCore
import NIOHTTP1
import Testing

@testable import ThinAppViewCore

@Suite("Tap repository boundary")
struct TapRepositoryTrackerTests {
  private let aliceDid = "did:plc:aaaaaaaaaaaaaaaaaaaaaaaa"
  private let bobDid = "did:plc:bbbbbbbbbbbbbbbbbbbbbbbb"

  @Test("registration survives restart and follows unsubscribe then re-enroll")
  func durableBoundaryReconciliation() async throws {
    let fixture = try makeFixture(limit: 10)
    try await fixture.store.replacePublicationScopes(
      viewerDid: "did:plc:viewer",
      scopes: [scope(authorDid: aliceDid)]
    )

    let first = try await fixture.makeTracker().runOnce()
    #expect(first.added == [aliceDid])
    #expect(await fixture.admin.additions == [[aliceDid]])

    // A fresh tracker reads the durable registration instead of re-adding from process memory.
    let afterRestart = try await fixture.makeTracker().runOnce()
    #expect(afterRestart.added.isEmpty)
    #expect(await fixture.admin.additions == [[aliceDid]])

    try await fixture.store.replacePublicationScopes(viewerDid: "did:plc:viewer", scopes: [])
    let removed = try await fixture.makeTracker().runOnce()
    #expect(removed.removed == [aliceDid])
    #expect(await fixture.admin.removals == [[aliceDid]])

    try await fixture.store.replacePublicationScopes(
      viewerDid: "did:plc:viewer",
      scopes: [scope(authorDid: aliceDid)]
    )
    let readded = try await fixture.makeTracker().runOnce()
    #expect(readded.added == [aliceDid])
    #expect(await fixture.admin.additions == [[aliceDid], [aliceDid]])
  }

  @Test("truncated desired scope fails before changing Tap")
  func truncatedScopeFailsClosed() async throws {
    let fixture = try makeFixture(limit: 1)
    try await fixture.store.replacePublicationScopes(
      viewerDid: "did:plc:viewer",
      scopes: [
        scope(authorDid: aliceDid),
        scope(authorDid: bobDid),
      ]
    )

    await #expect(throws: TapRepositoryTrackerError.desiredScopeTruncated(limit: 1)) {
      _ = try await fixture.makeTracker().runOnce()
    }
    #expect(await fixture.admin.additions.isEmpty)
    #expect(await fixture.admin.removals.isEmpty)
  }

  @Test("valid did:web scope survives earlier junk before truncation")
  func validatedScopePrecedesLimit() async throws {
    let fixture = try makeFixture(limit: 1)
    let webDid = "did:web:profiles.thesocialwire.app:authors:alice"
    try await fixture.store.replacePublicationScopes(
      viewerDid: "did:plc:viewer",
      scopes: [
        scope(authorDid: "did:not-a-repository"),
        scope(authorDid: "did:web:skyreader.rss"),
        scope(authorDid: webDid),
      ]
    )

    let result = try await fixture.makeTracker().runOnce()
    #expect(result.added == [webDid])
    #expect(await fixture.admin.additions == [[webDid]])
  }

  @Test("admin responses are drained on success and exact-status rejection")
  func adminResponseBodiesAreReleased() async throws {
    let successProbe = TapAdminBodyProbe()
    let successClient = HTTPTapRepositoryAdminClient(
      transport: StubTapRepositoryAdminHTTPTransport(
        response: Self.response(status: .noContent, probe: successProbe)
      ),
      baseURL: URL(string: "https://tap.internal")!,
      adminPassword: "secret"
    )
    try await successClient.addRepositories([aliceDid])
    #expect(await successProbe.readCount == 1)

    let rejectionProbe = TapAdminBodyProbe()
    let rejectionClient = HTTPTapRepositoryAdminClient(
      transport: StubTapRepositoryAdminHTTPTransport(
        response: Self.response(status: .tooManyRequests, probe: rejectionProbe)
      ),
      baseURL: URL(string: "https://tap.internal")!,
      adminPassword: "secret"
    )
    await #expect(throws: TapRepositoryTrackerError.rejected(statusCode: 429)) {
      try await rejectionClient.removeRepositories([aliceDid])
    }
    #expect(await rejectionProbe.readCount == 1)
  }

  private static func response(
    status: HTTPResponseStatus,
    probe: TapAdminBodyProbe
  ) -> HTTPClientResponse {
    HTTPClientResponse(
      status: status,
      body: .stream(TapAdminBodySequence(probe: probe))
    )
  }

  private func makeFixture(
    limit: Int
  ) throws -> (
    store: SQLiteThinAppViewStore,
    admin: RecordingTapRepositoryAdminClient,
    makeTracker: () -> TapRepositoryTracker
  ) {
    let path = NSTemporaryDirectory() + "tap-tracker-\(UUID().uuidString).sqlite"
    let logger = Logger(label: "tap-tracker.test")
    let store = try SQLiteThinAppViewStore(path: path, logger: logger)
    let admin = RecordingTapRepositoryAdminClient()
    let configuration = TapConsumerConfiguration(
      mode: .shadow,
      environment: "test",
      baseURL: URL(string: "http://127.0.0.1:2480")!,
      channelURL: URL(string: "ws://127.0.0.1:2480/channel")!,
      adminPassword: "secret",
      repoSyncLimit: limit
    )
    return (
      store,
      admin,
      {
        TapRepositoryTracker(
          store: store,
          adminClient: admin,
          configuration: configuration,
          logger: logger
        )
      }
    )
  }

  private func scope(authorDid: String) -> AppViewPublicationScope {
    AppViewPublicationScope(
      viewerDid: "did:plc:viewer",
      publicationId: "at://\(authorDid)/site.standard.publication/main",
      authorDid: authorDid,
      publicationAtUri: nil,
      publicationScopeAtUris: [],
      publicationSiteUrls: [],
      scopeKeys: [],
      sectionKeys: [],
      updatedAt: Date()
    )
  }
}

private actor RecordingTapRepositoryAdminClient: TapRepositoryAdminClient {
  private(set) var additions: [[String]] = []
  private(set) var removals: [[String]] = []

  func addRepositories(_ dids: [String]) {
    additions.append(dids)
  }

  func removeRepositories(_ dids: [String]) {
    removals.append(dids)
  }
}

private struct StubTapRepositoryAdminHTTPTransport: TapRepositoryAdminHTTPTransport {
  let response: HTTPClientResponse

  func execute(_ request: HTTPClientRequest, timeout: TimeAmount) async throws
    -> HTTPClientResponse
  {
    _ = request
    _ = timeout
    return response
  }
}

private actor TapAdminBodyProbe {
  private(set) var readCount = 0

  func recordRead() {
    readCount += 1
  }
}

private struct TapAdminBodySequence: AsyncSequence, Sendable {
  typealias Element = ByteBuffer

  struct AsyncIterator: AsyncIteratorProtocol {
    let probe: TapAdminBodyProbe
    var emitted = false

    mutating func next() async throws -> ByteBuffer? {
      guard !emitted else { return nil }
      emitted = true
      await probe.recordRead()
      var buffer = ByteBufferAllocator().buffer(capacity: 2)
      buffer.writeString("{}")
      return buffer
    }
  }

  let probe: TapAdminBodyProbe

  func makeAsyncIterator() -> AsyncIterator {
    AsyncIterator(probe: probe)
  }
}
