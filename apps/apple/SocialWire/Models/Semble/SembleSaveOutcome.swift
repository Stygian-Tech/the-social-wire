import Foundation

enum SembleSaveOutcome: Equatable, Sendable {
    case saved(card: StrongRef)
    case membershipRetry(SembleSaveRetryState, message: String)
}
