import Foundation
import Testing
@testable import WireWorkerCore

@Suite("The Wire baseline label refresh")
struct WireBaselineLabelRefresherTests {
  private let now = Date(timeIntervalSince1970: 2_000_000_000)
  private let labeler = try! WireLabelerEndpoint.parse(WireLabelerEndpoint.blueskyDefault)[0]

  @Test("projects record and author labels and applies negation and expiry")
  func projectsBaselineLabels() async throws {
    let store = FakeBaselineLabelStore(
      targets: [
        WireBaselineLabelTarget(
          canonicalKey: "story-a",
          representativeURI: "at://did:example:author/site.standard.document/a",
          authorDID: "did:example:author"
        ),
        WireBaselineLabelTarget(
          canonicalKey: "story-b",
          representativeURI: "at://did:example:author/site.standard.document/b",
          authorDID: "did:example:author"
        ),
      ]
    )
    let client = FakeLabelQueryClient(pages: [
      nil: WireLabelQueryPage(
        cursor: "next",
        labels: [
          record(uri: "at://did:example:author/site.standard.document/a", value: "!hide"),
          record(uri: "did:example:author", value: "spam"),
          record(uri: "did:example:author", value: "porn", negated: true),
        ]
      ),
      "next": WireLabelQueryPage(
        cursor: nil,
        labels: [
          record(uri: "at://did:example:author/site.standard.document/b", value: "graphic-media"),
          record(
            uri: "at://did:example:author/site.standard.document/b",
            value: "sexual",
            expiresAt: "2020-01-01T00:00:00Z"
          ),
        ]
      ),
    ])
    let refresher = WireBaselineLabelRefresher(
      store: store,
      queryClient: client,
      labelers: [labeler],
      candidateLimit: 100,
      maximumAge: 900
    )

    try await refresher.refresh(asOf: now)

    let snapshot = await store.snapshot()
    #expect(snapshot.replaceCount == 1)
    #expect(snapshot.verifyCount == 1)
    #expect(snapshot.targetCount == 2)
    #expect(snapshot.labels.count == 4)
    #expect(snapshot.labels.contains { $0.canonicalKey == "story-a" && $0.labelValue == "exclude" })
    #expect(snapshot.labels.filter { $0.labelValue == "spam" }.map(\.canonicalKey).sorted() == [
      "story-a", "story-b",
    ])
    #expect(snapshot.labels.contains { $0.canonicalKey == "story-b" && $0.labelValue == "graphic" })
    #expect(!snapshot.labels.contains { $0.labelValue == "adult" })
    #expect(snapshot.labels.allSatisfy { !$0.source.contains("did:example:author") })
    let requests = await client.requests
    #expect(requests.count == 2)
    #expect(requests.allSatisfy { $0.patterns.count <= 25 })
  }

  @Test("rejects labels attributed to an unconfigured source")
  func rejectsUnexpectedSource() async {
    let store = FakeBaselineLabelStore(
      targets: [WireBaselineLabelTarget(
        canonicalKey: "story",
        representativeURI: "at://did:example:author/site.standard.document/story",
        authorDID: nil
      )]
    )
    let client = FakeLabelQueryClient(pages: [
      nil: WireLabelQueryPage(
        cursor: nil,
        labels: [WireLabelQueryRecord(
          sourceDID: "did:example:unexpected",
          subjectURI: "at://did:example:author/site.standard.document/story",
          value: "!takedown",
          negated: false,
          createdAt: "2033-05-18T03:33:20Z",
          expiresAt: nil
        )]
      )
    ])
    let refresher = WireBaselineLabelRefresher(
      store: store,
      queryClient: client,
      labelers: [labeler],
      candidateLimit: 100,
      maximumAge: 900
    )

    await #expect(throws: WireLabelQueryError.incompleteResponse) {
      try await refresher.refresh(asOf: now)
    }
    #expect(await store.snapshot().replaceCount == 0)
  }

  @Test("repeated cursors fail before replacing the last good snapshot")
  func repeatedCursorFailsClosed() async {
    let store = FakeBaselineLabelStore(
      targets: [WireBaselineLabelTarget(
        canonicalKey: "story",
        representativeURI: "at://did:example:author/site.standard.document/story",
        authorDID: nil
      )]
    )
    let client = FakeLabelQueryClient(pages: [
      nil: WireLabelQueryPage(cursor: "same", labels: []),
      "same": WireLabelQueryPage(cursor: "same", labels: []),
    ])
    let refresher = WireBaselineLabelRefresher(
      store: store,
      queryClient: client,
      labelers: [labeler],
      candidateLimit: 100,
      maximumAge: 900
    )

    await #expect(throws: WireLabelQueryError.repeatedCursor) {
      try await refresher.refresh(asOf: now)
    }
    #expect(await store.snapshot().replaceCount == 0)
  }

  @Test("the whole baseline refresh has a bounded deadline")
  func refreshDeadline() async {
    let store = FakeBaselineLabelStore(
      targets: [WireBaselineLabelTarget(
        canonicalKey: "story",
        representativeURI: "at://did:example:author/site.standard.document/story",
        authorDID: nil
      )]
    )
    let refresher = WireBaselineLabelRefresher(
      store: store,
      queryClient: SlowLabelQueryClient(),
      labelers: [labeler],
      candidateLimit: 100,
      maximumAge: 900,
      refreshTimeout: .milliseconds(10)
    )

    await #expect(throws: WireLabelQueryError.refreshTimedOut) {
      try await refresher.refresh(asOf: now)
    }
    #expect(await store.snapshot().replaceCount == 0)
  }

  @Test("successful snapshots throttle external label queries while remaining fail closed")
  func throttlesRecentSnapshot() async throws {
    let store = FakeBaselineLabelStore(targets: [])
    let client = FakeLabelQueryClient(pages: [
      nil: WireLabelQueryPage(cursor: nil, labels: [])
    ])
    let refresher = WireBaselineLabelRefresher(
      store: store,
      queryClient: client,
      labelers: [labeler],
      candidateLimit: 100,
      maximumAge: 900,
      minimumRefreshInterval: 300
    )

    try await refresher.refresh(asOf: now)
    try await refresher.refresh(asOf: now.addingTimeInterval(60))

    #expect(await client.requests.count == 1)
    let snapshot = await store.snapshot()
    #expect(snapshot.replaceCount == 1)
    #expect(snapshot.verifyCount == 2)
  }

  private func record(
    uri: String,
    value: String,
    negated: Bool = false,
    expiresAt: String? = nil
  ) -> WireLabelQueryRecord {
    WireLabelQueryRecord(
      sourceDID: labeler.sourceDID,
      subjectURI: uri,
      value: value,
      negated: negated,
      createdAt: "2033-05-18T03:33:20Z",
      expiresAt: expiresAt
    )
  }
}

private actor FakeBaselineLabelStore: WireBaselineLabelStore {
  struct Snapshot: Sendable {
    let labels: [WireBaselineLabel]
    let targetCount: Int
    let replaceCount: Int
    let verifyCount: Int
  }

  private let targets: [WireBaselineLabelTarget]
  private var labels: [WireBaselineLabel] = []
  private var targetCount = 0
  private var replaceCount = 0
  private var verifyCount = 0

  init(targets: [WireBaselineLabelTarget]) { self.targets = targets }

  func loadTargets(limit: Int, asOf: Date) -> [WireBaselineLabelTarget] {
    Array(targets.prefix(limit))
  }

  func replaceSnapshot(
    labels: [WireBaselineLabel],
    labelers: [WireLabelerEndpoint],
    refreshedCanonicalKeys: [String],
    targetCount: Int,
    refreshedAt: Date
  ) {
    self.labels = labels
    self.targetCount = targetCount
    replaceCount += 1
  }

  func verifyFresh(
    labelers: [WireLabelerEndpoint],
    asOf: Date,
    maximumAge: TimeInterval
  ) {
    verifyCount += 1
  }

  func snapshot() -> Snapshot {
    Snapshot(
      labels: labels,
      targetCount: targetCount,
      replaceCount: replaceCount,
      verifyCount: verifyCount
    )
  }
}

private struct SlowLabelQueryClient: WireLabelQuerying {
  func query(
    labeler: WireLabelerEndpoint,
    uriPatterns: [String],
    cursor: String?
  ) async throws -> WireLabelQueryPage {
    try await Task.sleep(for: .seconds(60))
    return WireLabelQueryPage(cursor: nil, labels: [])
  }
}

private actor FakeLabelQueryClient: WireLabelQuerying {
  struct Request: Sendable {
    let patterns: [String]
    let cursor: String?
  }

  private let pages: [String: WireLabelQueryPage]
  private let firstPage: WireLabelQueryPage?
  private(set) var requests: [Request] = []

  init(pages: [String?: WireLabelQueryPage]) {
    var keyed: [String: WireLabelQueryPage] = [:]
    var first: WireLabelQueryPage?
    for (cursor, page) in pages {
      if let cursor { keyed[cursor] = page } else { first = page }
    }
    self.pages = keyed
    firstPage = first
  }

  func query(
    labeler: WireLabelerEndpoint,
    uriPatterns: [String],
    cursor: String?
  ) throws -> WireLabelQueryPage {
    requests.append(Request(patterns: uriPatterns, cursor: cursor))
    if let cursor, let page = pages[cursor] { return page }
    if cursor == nil, let firstPage { return firstPage }
    throw WireLabelQueryError.invalidResponse
  }
}
