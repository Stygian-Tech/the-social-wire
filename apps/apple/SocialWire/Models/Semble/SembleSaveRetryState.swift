import Foundation

struct SembleSaveRetryState: Codable, Equatable, Sendable {
    let collectionURI: String
    let card: StrongRef
    let normalizedURL: String
    let title: String?
}
