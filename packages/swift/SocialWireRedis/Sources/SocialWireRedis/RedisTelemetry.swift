import Foundation

public struct RedisTelemetryEvent: Sendable, Equatable {
  public enum Kind: String, Sendable {
    case operation
    case error
    case circuitState
    case cacheLookup
    case lock
    case resourceSample
  }

  public let kind: Kind
  public let operation: String
  public let outcome: String
  public let durationMilliseconds: Double?
  public let value: Double?

  public init(
    kind: Kind,
    operation: String,
    outcome: String,
    durationMilliseconds: Double? = nil,
    value: Double? = nil
  ) {
    self.kind = kind
    self.operation = operation
    self.outcome = outcome
    self.durationMilliseconds = durationMilliseconds
    self.value = value
  }
}

public typealias RedisTelemetrySink = @Sendable (RedisTelemetryEvent) -> Void
