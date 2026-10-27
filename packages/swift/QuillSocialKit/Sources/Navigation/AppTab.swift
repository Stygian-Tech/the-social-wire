/// Top-level destinations. Shown as a bottom tab bar in compact width and as a sidebar in regular width.
public enum AppTab: String, CaseIterable, Codable, Hashable, Sendable {
    case home
    case search
    case chat
    case notifications
    case profile
}
