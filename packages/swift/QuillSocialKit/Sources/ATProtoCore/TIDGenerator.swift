import Foundation
import Synchronization

/// Produces strictly increasing TIDs for new records, even when called faster than the clock ticks.
public final class TIDGenerator: Sendable {
    private let lastMicroseconds = Mutex<UInt64>(0)
    private let clockID: UInt16
    private let now: @Sendable () -> Date

    public init(clockID: UInt16 = .random(in: 0..<1024), now: @escaping @Sendable () -> Date = Date.init) {
        self.clockID = clockID
        self.now = now
    }

    public func next() -> TID {
        let current = UInt64(max(0, now().timeIntervalSince1970) * 1_000_000)
        let microseconds = lastMicroseconds.withLock { last in
            last = max(current, last + 1)
            return last
        }
        return TID(microseconds: microseconds, clockID: clockID)
    }
}
