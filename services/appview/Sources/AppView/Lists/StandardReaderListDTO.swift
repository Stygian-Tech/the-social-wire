import Foundation
import Hummingbird

struct StandardReaderListDTO: Codable, Sendable, Equatable, ResponseEncodable {
  let uri: String
  let name: String
  let description: String?
  let creatorDid: String
  let publications: [String]
  let users: [String]
  let owned: Bool
  let saved: Bool
  var publicationDetails: [StandardReaderListPublicationDTO]? = nil
}

struct StandardReaderListsResponse: Codable, Sendable, ResponseEncodable {
  let lists: [StandardReaderListDTO]
  let refreshedAt: String
  let complete: Bool
  var creatorDid: String? = nil
}

struct StandardReaderListResolveRequest: Codable, Sendable {
  let input: String
}

struct StandardReaderListResolveResponse: Codable, Sendable, ResponseEncodable {
  let list: StandardReaderListDTO
}
