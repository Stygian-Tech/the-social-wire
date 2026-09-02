import Foundation

struct FeedReadAgeResponse: Decodable, Sendable {
    let referenceDay: String
    let options: [FeedReadAgeOption]
}
