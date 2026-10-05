import Foundation

/// Keeps list discovery from flooding shared PDS resolution and HTTP pools.
actor StandardReaderPreparationLimiter {
  private var active = 0
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func acquire() async {
    if active < 2 { active += 1; return }
    await withCheckedContinuation { waiters.append($0) }
  }

  func release() {
    if waiters.isEmpty { active -= 1 }
    else { waiters.removeFirst().resume() }
  }
}
