import Foundation

public enum AppViewFeedKind: String, Codable, Sendable, Equatable {
  case subscribed
  case following
  case folder
  case publication
  case list

  public var requiresId: Bool {
    self == .folder || self == .publication || self == .list
  }
}
