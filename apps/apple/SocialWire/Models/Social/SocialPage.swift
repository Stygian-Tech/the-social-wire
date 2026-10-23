import Foundation

struct SocialPage<Element: Sendable>: Sendable {
    let items: [Element]
    let cursor: String?
}
