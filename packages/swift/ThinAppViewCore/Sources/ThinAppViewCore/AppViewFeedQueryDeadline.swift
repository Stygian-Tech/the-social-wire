import Foundation

/// One monotonic budget follows feed reads through pool acquisition and retry.
public struct AppViewFeedQueryDeadline: Sendable {
  public enum Failure: Error { case exceeded }

  @TaskLocal public static var current: AppViewFeedQueryDeadline?
  public let instant: ContinuousClock.Instant

  public init(duration: Duration = .seconds(2), startedAt: ContinuousClock.Instant = .now) {
    instant = startedAt.advanced(by: duration)
  }

  public func check(at now: ContinuousClock.Instant = .now) throws {
    try Task.checkCancellation()
    guard now < instant else { throw Failure.exceeded }
  }

  func statementMilliseconds(at now: ContinuousClock.Instant = .now) throws -> Int {
    try check(at: now)
    // Leave time for the server's cancellation reply and transaction completion inside
    // the request deadline. Never round a sub-millisecond timeout down to PostgreSQL's zero.
    let remaining = now.duration(to: instant) - .milliseconds(25)
    guard remaining >= .milliseconds(1) else { throw Failure.exceeded }
    let parts = remaining.components
    return Int(parts.seconds * 1_000 + parts.attoseconds / 1_000_000_000_000_000)
  }
}
