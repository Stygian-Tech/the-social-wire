import Foundation
import Logging
import OperationsCore
import Testing
@testable import ThinAppViewCore

@Suite("Legacy Jetstream authority lease")
struct LegacyJetstreamAuthorityLeaseTests {
  @Test("authority waits for takeover and stops when renewal loses its fencing token")
  func takeoverAndRenewalLoss() async throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("legacy-authority-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: url) }
    let store = try SQLiteOperationsStore(
      path: url.path, environment: "dev", logger: Logger(label: "legacy-authority.store.test"))
    let initial = Date()
    let external = try #require(await store.acquireIngestionLeaderLease(
      name: LegacyJetstreamAuthorityLease.leaseName,
      sourceGeneration: LegacyJetstreamAuthorityLease.sourceGeneration,
      ownerID: "external",
      leaseUntil: initial.addingTimeInterval(1),
      at: initial
    ))
    let state = AuthorityState()
    let runner = Task {
      await LegacyJetstreamAuthorityLease.runForever(
        store: store,
        ownerID: "worker",
        leaseSeconds: 0.15,
        minimumLeaseSeconds: 0.05,
        contentionSleepSeconds: 0.01,
        logger: Logger(label: "legacy-authority.test")
      ) { _ in
        await state.started()
        while !Task.isCancelled {
          try? await Task.sleep(for: .milliseconds(5))
        }
        await state.stopped()
      }
    }

    try await Task.sleep(for: .milliseconds(40))
    #expect(await state.startCount() == 0)
    try await store.releaseIngestionLeaderLease(
      name: external.name, ownerID: external.ownerID,
      fencingToken: external.fencingToken, at: Date())
    try await waitUntil { await state.isActive() }

    let workerLease = try #require(await store.acquireIngestionLeaderLease(
      name: LegacyJetstreamAuthorityLease.leaseName,
      sourceGeneration: LegacyJetstreamAuthorityLease.sourceGeneration,
      ownerID: "worker",
      leaseUntil: Date().addingTimeInterval(0.15),
      at: Date()
    ))
    try await store.releaseIngestionLeaderLease(
      name: workerLease.name, ownerID: workerLease.ownerID,
      fencingToken: workerLease.fencingToken, at: Date())
    _ = try #require(await store.acquireIngestionLeaderLease(
      name: LegacyJetstreamAuthorityLease.leaseName,
      sourceGeneration: LegacyJetstreamAuthorityLease.sourceGeneration,
      ownerID: "takeover",
      leaseUntil: Date().addingTimeInterval(1),
      at: Date()
    ))
    try await waitUntil { !(await state.isActive()) }
    runner.cancel()
    await runner.value
    #expect(await state.startCount() == 1)
  }

  @Test("an in-flight fence delays takeover and a stale token cannot enter another operation")
  func operationFenceBlocksTakeover() async throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("legacy-fence-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: url) }
    let store = try SQLiteOperationsStore(
      path: url.path, environment: "dev", logger: Logger(label: "legacy-fence.store.test"))
    let now = Date()
    let first = try #require(await store.acquireIngestionLeaderLease(
      name: LegacyJetstreamAuthorityLease.leaseName,
      sourceGeneration: LegacyJetstreamAuthorityLease.sourceGeneration,
      ownerID: "worker-a",
      leaseUntil: now.addingTimeInterval(0.05),
      at: now
    ))
    let control = FenceControl()
    let fenced = Task {
      try await store.withIngestionLeaderLeaseFence(
        name: first.name,
        ownerID: first.ownerID,
        fencingToken: first.fencingToken,
        at: now
      ) {
        await control.enter()
        while !(await control.mayLeave()) {
          try await Task.sleep(for: .milliseconds(5))
        }
      }
    }
    try await waitUntil { await control.didEnter() }
    try await Task.sleep(for: .milliseconds(60))
    #expect(try await store.acquireIngestionLeaderLease(
      name: first.name,
      sourceGeneration: first.sourceGeneration,
      ownerID: "worker-b",
      leaseUntil: Date().addingTimeInterval(1),
      at: Date()
    ) == nil)
    await control.release()
    try await fenced.value

    let takeover = try #require(await store.acquireIngestionLeaderLease(
      name: first.name,
      sourceGeneration: first.sourceGeneration,
      ownerID: "worker-b",
      leaseUntil: Date().addingTimeInterval(1),
      at: Date()
    ))
    #expect(takeover.fencingToken > first.fencingToken)
    let staleOperation = FenceControl()
    await #expect(throws: OperationsStoreError.leaseConflict) {
      try await store.withIngestionLeaderLeaseFence(
        name: first.name,
        ownerID: first.ownerID,
        fencingToken: first.fencingToken,
        at: Date()
      ) {
        await staleOperation.enter()
      }
    }
    #expect(!(await staleOperation.didEnter()))
  }

  @Test("a drained frame with a stale token cannot mutate or commit")
  func staleDrainedFrameCannotProject() async throws {
    let base = FileManager.default.temporaryDirectory
      .appendingPathComponent("legacy-stale-frame-\(UUID().uuidString)")
    let appViewPath = base.appendingPathExtension("appview.sqlite")
    let operationsPath = base.appendingPathExtension("operations.sqlite")
    defer {
      try? FileManager.default.removeItem(at: appViewPath)
      try? FileManager.default.removeItem(at: operationsPath)
    }
    let logger = Logger(label: "legacy-stale-frame.test")
    let appViewStore = try SQLiteThinAppViewStore(path: appViewPath.path, logger: logger)
    let operationsStore = try SQLiteOperationsStore(
      path: operationsPath.path, environment: "dev", logger: logger)
    let config = ThinAppViewConfig.fromEnvironment(["ENABLE_THIN_APPVIEW": "true"])
    let subscriber = FirehoseSubscriber(
      relayURLs: config.relayWebSocketURLs,
      indexer: ThinAppViewIndexer(store: appViewStore, config: config, logger: logger),
      operationsStore: operationsStore,
      telemetry: nil,
      environment: "dev",
      instanceId: "worker-a",
      replayRewindMicroseconds: 5_000_000,
      logger: logger
    )
    let now = Date()
    let first = try #require(await operationsStore.acquireIngestionLeaderLease(
      name: LegacyJetstreamAuthorityLease.leaseName,
      sourceGeneration: LegacyJetstreamAuthorityLease.sourceGeneration,
      ownerID: "worker-a",
      leaseUntil: now.addingTimeInterval(1),
      at: now
    ))
    try await operationsStore.releaseIngestionLeaderLease(
      name: first.name, ownerID: first.ownerID,
      fencingToken: first.fencingToken, at: Date())
    _ = try #require(await operationsStore.acquireIngestionLeaderLease(
      name: first.name,
      sourceGeneration: first.sourceGeneration,
      ownerID: "worker-b",
      leaseUntil: Date().addingTimeInterval(1),
      at: Date()
    ))
    let uri = "at://did:plc:stale/site.standard.entry/article"
    let message = """
      {"did":"did:plc:stale","time_us":1700000000000000,"kind":"commit","commit":{
      "operation":"create","collection":"site.standard.entry","rkey":"article",
      "cid":"bafystale","record":{"$type":"site.standard.entry","title":"Stale"}}}
      """
    await #expect(throws: OperationsStoreError.leaseConflict) {
      try await subscriber.handleMessage(message, authorityLease: first)
    }
    #expect(try await appViewStore.fetchContentIdentity(uri: uri) == nil)
    #expect(try await operationsStore.fetchStreamState(source: "jetstream")?.lastCommittedCursor == nil)
  }

  private func waitUntil(
    _ predicate: @escaping @Sendable () async -> Bool
  ) async throws {
    for _ in 0..<100 {
      if await predicate() { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("Timed out waiting for lease state")
  }
}

private actor AuthorityState {
  private var active = false
  private var starts = 0

  func started() {
    active = true
    starts += 1
  }

  func stopped() { active = false }
  func isActive() -> Bool { active }
  func startCount() -> Int { starts }
}

private actor FenceControl {
  private var entered = false
  private var released = false

  func enter() { entered = true }
  func release() { released = true }
  func didEnter() -> Bool { entered }
  func mayLeave() -> Bool { released }
}
