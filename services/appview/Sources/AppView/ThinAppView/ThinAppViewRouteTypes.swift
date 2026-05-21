import Foundation
import GatewayCore
import Hummingbird
import GatewayCore

struct AppViewEnrollResponse: Codable, Sendable {
  let indexed: Int
}

extension AppViewEnrollResponse: ResponseEncodable {}
