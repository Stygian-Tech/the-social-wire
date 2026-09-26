import Foundation

/// An immutable repository record reference. A loader must verify the returned CID.
public struct ReadStateReference: Codable, Sendable, Equatable, Hashable {
  public let uri: String
  public let cid: String

  public init(uri: String, cid: String) {
    self.uri = uri
    self.cid = cid
  }
}
