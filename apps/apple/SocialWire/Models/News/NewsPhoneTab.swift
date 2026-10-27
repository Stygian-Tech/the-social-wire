import Foundation

/// Browse remains available when a destination isn't one of the viewer's shortcuts.
enum NewsPhoneTab: Hashable {
    case section(NewsRootSection)
    case browse
}
