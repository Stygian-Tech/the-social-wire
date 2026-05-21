import Foundation
import GatewayCore
import Hummingbird

struct AppViewEnrollResponse: Codable, Sendable {
  let indexed: Int
}

extension AppViewEnrollResponse: ResponseEncodable {}
