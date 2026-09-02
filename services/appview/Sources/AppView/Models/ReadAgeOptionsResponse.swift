import Hummingbird

struct ReadAgeOptionsResponse: Codable, Sendable, ResponseEncodable {
  let options: [ReadAgeOption]
  let referenceDay: String
}
