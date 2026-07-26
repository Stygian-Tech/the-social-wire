import Foundation

public struct GapInvestigationEvidence: Codable, Sendable, Identifiable {
  public enum Kind: String, Codable, Sendable {
    case gap
    case stream
    case indexing
    case service
    case alert
    case trace
  }

  public let id: String
  public let kind: Kind
  public let occurredAt: Date
  public let service: String
  public let title: String
  public let detail: String
  public let attributes: [String: String]
  public let traceId: String?

  public init(
    id: String,
    kind: Kind,
    occurredAt: Date,
    service: String,
    title: String,
    detail: String,
    attributes: [String: String] = [:],
    traceId: String? = nil
  ) {
    self.id = id
    self.kind = kind
    self.occurredAt = occurredAt
    self.service = service
    self.title = title
    self.detail = detail
    self.attributes = attributes
    self.traceId = traceId
  }
}
