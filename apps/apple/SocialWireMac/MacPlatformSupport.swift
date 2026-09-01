#if os(macOS)
import AppKit

/// UIKit-compatible semantic names used by shared SwiftUI views.
/// Values remain dynamic so appearance changes are handled by AppKit.
extension NSColor {
    static var systemBackground: NSColor { windowBackgroundColor }
    static var systemGroupedBackground: NSColor { underPageBackgroundColor }
    static var tertiarySystemFill: NSColor { tertiaryLabelColor.withAlphaComponent(0.12) }
}
#endif
