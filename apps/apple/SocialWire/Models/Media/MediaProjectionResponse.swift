import Foundation

/// Portrait classification is independent of duration; callers must not infer verified shortform.
struct MediaProjectionResponse: Decodable, Sendable {
    let uris: [String]
    let source: String
    let selection: String
    let durationVerified: Bool
    let unsupportedSources: [String]
}
