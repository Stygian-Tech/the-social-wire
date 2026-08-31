import SwiftUI

struct AppAppearanceModifier: ViewModifier {
    @AppStorage("the-social-wire.theme.v1") private var themeRaw = AppThemePreference.system.rawValue
    @AppStorage("the-social-wire.font.v1") private var fontRaw = AppFontPreference.sans.rawValue
    @AppStorage("the-social-wire.bold-text.v1") private var boldText = false

    func body(content: Content) -> some View {
        content
            .preferredColorScheme(theme.colorScheme)
            .fontDesign(font.design)
            .fontWeight(boldText ? .bold : nil)
    }

    private var theme: AppThemePreference {
        AppThemePreference(rawValue: themeRaw) ?? .system
    }

    private var font: AppFontPreference {
        AppFontPreference(rawValue: fontRaw) ?? .sans
    }
}

extension View {
    func appAppearance() -> some View {
        modifier(AppAppearanceModifier())
    }
}
