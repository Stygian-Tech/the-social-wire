import Foundation

public struct AppViewFeedSelector: Codable, Sendable, Equatable {
  public let kind: AppViewFeedKind
  public let id: String

  public init(kind: AppViewFeedKind, id: String? = nil) {
    self.kind = kind
    let trimmed = id?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if kind == .folder, trimmed.hasPrefix("at://") {
      self.id = trimmed.split(separator: "/").last.map(String.init) ?? trimmed
    } else {
      self.id = trimmed
    }
  }
}
