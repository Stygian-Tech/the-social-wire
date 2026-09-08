import Foundation
import Testing
@testable import ReadStateCore

@Suite struct ReadStateOutboxOwnershipTests {
  @Test(arguments: [false, true])
  func lateOldResponseCannotOverwriteReloggedViewerQueue(fails: Bool) async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appending(path: "outbox.json")
    let gate = OwnershipManifestGate()
    let transport = ReadStateSyncTransport(readManifest: { try await gate.read() },
      loadProjection: { _ in try ReadStateProjection(operations: [], lastSequence: 0) },
      putChunk: { _, _ in throw ReadStateSyncFailure.conflict },
      putManifest: { _, _ in throw ReadStateSyncFailure.conflict },
      confirm: { _, _ in throw ReadStateSyncFailure.conflict })
    let old = try ReadStateSyncEngine(viewerDid: "did:plc:viewer", file: file, transport: transport)
    try await old.enqueue([operation("before-sign-out", uri: "story-a")])
    let oldFlush = Task { try await old.flush() }
    await gate.waitUntilEntered()

    // Re-login loads the same durable queue while the previous session awaits I/O.
    let current = try ReadStateSyncEngine(viewerDid: "did:plc:viewer", file: file, transport: transport)
    try await current.enqueue([operation("after-sign-in", uri: "story-b")])
    await gate.resume(fails: fails)
    await #expect(throws: ReadStateSyncFailure.self) { try await oldFlush.value }
    // A stale caller is fenced even if it tries a subsequent enqueue.
    await #expect(throws: ReadStateSyncFailure.self) {
      try await old.enqueue([operation("stale-caller", uri: "story-c")])
    }
    let restarted = try ReadStateSyncEngine(viewerDid: "did:plc:viewer", file: file, transport: transport)
    #expect(await restarted.pendingCount == 2)
    #expect(await restarted.pendingLocalOperations.map(\.actionId) == ["before-sign-out", "after-sign-in"])
  }

  @Test func rejectedViewerCannotStealQueueOwnership() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appending(path: "outbox.json")
    let first = ReadStateOutboxStorage(file: file)
    let outbox = try first.claim(viewerDid: "did:plc:alice")
    try first.write(outbox)
    let wrongViewer = ReadStateOutboxStorage(file: file)
    #expect(throws: ReadStateSyncFailure.self) { try wrongViewer.claim(viewerDid: "did:plc:bob") }
    try first.write(outbox)
    let nextOwner = ReadStateOutboxStorage(file: file)
    _ = try nextOwner.claim(viewerDid: "did:plc:alice")
    #expect(throws: ReadStateSyncFailure.self) { try first.write(outbox) }
    try nextOwner.write(outbox)
  }

  private func operation(_ id: String, uri: String) -> ReadStateOperation {
    .init(actionId: id, sequence: 1, state: .unread, actedAt: "2026-09-08T00:00:00Z", subjectUris: [uri])
  }
}

private actor OwnershipManifestGate {
  private var continuation: CheckedContinuation<ReadStateManifestRecord?, any Error>?
  func read() async throws -> ReadStateManifestRecord? {
    try await withCheckedThrowingContinuation { continuation = $0 }
  }
  func waitUntilEntered() async {
    while continuation == nil { await Task.yield() }
  }
  func resume(fails: Bool) {
    if fails { continuation?.resume(throwing: ReadStateSyncFailure.accountChanged) }
    else { continuation?.resume(returning: .init(manifest: .init(generation: "active", lastSequence: 0, head: nil), cid: "active")) }
    continuation = nil
  }
}
