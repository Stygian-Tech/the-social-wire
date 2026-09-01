import Foundation

/// Lightweight route values shared by each tab's independent navigation stack.
enum NewsRoute: Codable, Hashable, Sendable {
    case entry(id: String)
    case publication(id: String)
    case savedLink(id: String)
    case sembleItem(id: String)
    case profile
    case settings
}
