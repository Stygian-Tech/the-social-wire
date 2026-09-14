import Foundation

struct ReadAgeStreamEvent: Encodable, Sendable {
  let type: String
  var options: [ReadAgeOption]? = nil
  var referenceDay: String? = nil
  var message: String? = nil
}
