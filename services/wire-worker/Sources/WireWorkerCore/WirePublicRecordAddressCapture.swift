import Foundation

/// The blocking resolver finishes on a detached task after cancellation or timeout.
/// Only the resolver and its awaiting caller share this lock-protected value.
final class WirePublicRecordAddressCapture: @unchecked Sendable {
  private let lock = NSLock()
  private var value: [String]?

  func store(_ addresses: [String]?) {
    lock.lock()
    defer { lock.unlock() }
    value = addresses
  }

  func first() -> String? {
    lock.lock()
    defer { lock.unlock() }
    return value?.first
  }
}
