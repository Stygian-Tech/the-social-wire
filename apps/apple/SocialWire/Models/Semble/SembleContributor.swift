import Foundation

struct SembleContributor: Codable, Equatable, Sendable {
    let did: String
    let handle: String?
    let displayName: String?
    let avatar: String?

    var label: String {
        if let displayName, !displayName.isEmpty { return displayName }
        if let handle, !handle.isEmpty { return "@\(handle)" }
        return did
    }
}
