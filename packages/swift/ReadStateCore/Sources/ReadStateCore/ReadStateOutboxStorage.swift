import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// A new engine takes ownership while reading the latest durable queue. An older
/// engine may finish an in-flight request, but cannot persist over its successor.
final class ReadStateOutboxStorage: Sendable {
  private let file: URL
  private let owner = UUID().uuidString

  init(file: URL) {
    self.file = file.standardizedFileURL.resolvingSymlinksInPath()
  }

  func claim(viewerDid: String) throws -> ReadStateOutbox {
    try withFileLock {
      let outbox: ReadStateOutbox
      if FileManager.default.fileExists(atPath: file.path) {
        outbox = try JSONDecoder().decode(ReadStateOutbox.self, from: Data(contentsOf: file))
        guard outbox.viewerDid == viewerDid else { throw ReadStateSyncFailure.accountChanged }
      } else {
        outbox = ReadStateOutbox(viewerDid: viewerDid)
      }
      try Data(owner.utf8).write(to: file.appendingPathExtension("owner"), options: .atomic)
      return outbox
    }
  }

  func write(_ outbox: ReadStateOutbox) throws {
    let data = try JSONEncoder().encode(outbox)
    try withFileLock {
      let currentOwner = try Data(contentsOf: file.appendingPathExtension("owner"))
      guard currentOwner == Data(owner.utf8) else { throw ReadStateSyncFailure.accountChanged }
      try data.write(to: file, options: .atomic)
    }
  }

  private func withFileLock<T>(_ operation: () throws -> T) throws -> T {
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    // Lock a stable sidecar inode: the queue and owner files are replaced atomically.
    // flock also serializes independent app processes sharing this outbox path.
    let descriptor = open(file.appendingPathExtension("lock").path, O_CREAT | O_RDWR, mode_t(0o600))
    guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    defer { _ = close(descriptor) }
    guard flock(descriptor, LOCK_EX) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    defer { _ = flock(descriptor, LOCK_UN) }
    return try operation()
  }
}
