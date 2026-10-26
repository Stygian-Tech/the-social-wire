import Foundation

struct MediaProjectionRequest: Encodable, Sendable {
    let mode: MediaProjectionMode
    let posts: [MediaProjectionCandidate]
}
