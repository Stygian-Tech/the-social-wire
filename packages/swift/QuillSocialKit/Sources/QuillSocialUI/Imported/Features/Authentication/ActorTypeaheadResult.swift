#if os(iOS)
import Foundation

struct ActorTypeaheadResult: Decodable, Identifiable, Sendable {
    let did: String
    let handle: String
    let displayName: String?
    let avatar: URL?

    var id: String { did }
}

#endif
