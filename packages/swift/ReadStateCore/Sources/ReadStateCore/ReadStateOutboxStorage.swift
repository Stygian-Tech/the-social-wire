import Foundation

/// Read-state queue adapter retaining the existing cross-session ownership fence.
final class ReadStateOutboxStorage: Sendable {
  private let storage: ReadStateOwnedFileStorage<ReadStateOutbox>
  init(file: URL) { storage = .init(file: file) }
  func claim(viewerDid: String) throws -> ReadStateOutbox {
    try storage.claim(initial: .init(viewerDid: viewerDid)) { $0.viewerDid == viewerDid }
  }
  func write(_ outbox: ReadStateOutbox) throws { try storage.write(outbox) }
}
