import Foundation

/// Only the post identity and official embed view are sent to the projection service.
struct MediaProjectionCandidate: Encodable, Sendable {
    let uri: String
    let embed: JSONValue
}
