import Foundation

struct SocialProEntitlement: Decodable, Equatable, Sendable {
    let viewerDid: String
    let plan: Plan

    enum Plan: String, Decodable, Sendable {
        case free
        case pro
    }
}
