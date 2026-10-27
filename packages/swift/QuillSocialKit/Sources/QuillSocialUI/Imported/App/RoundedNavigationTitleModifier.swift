#if os(iOS)
import SwiftUI

struct RoundedNavigationTitleModifier: ViewModifier {
    let title: LocalizedStringResource
    let usesLargeTitle: Bool
    let largeTitleFont: Font
    let inlineTitleFont: Font

    func body(content: Content) -> some View {
        content
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(usesLargeTitle ? .large : .inline)
            .toolbar {
                if #available(iOS 26, *), usesLargeTitle {
                    ToolbarItem(placement: .largeTitle) {
                        Text(title)
                            .font(largeTitleFont)
                            .fontDesign(.rounded)
                            .lineLimit(1)
                    }
                } else {
                    ToolbarItem(placement: .principal) {
                        Text(title)
                            .font(inlineTitleFont)
                            .fontDesign(.rounded)
                            .lineLimit(1)
                    }
                }
            }
    }
}

extension View {
    func roundedNavigationTitle(
        _ title: LocalizedStringResource,
        usesLargeTitle: Bool = false,
        largeTitleFont: Font = .title.bold(),
        inlineTitleFont: Font = .subheadline.weight(.semibold)
    ) -> some View {
        modifier(
            RoundedNavigationTitleModifier(
                title: title,
                usesLargeTitle: usesLargeTitle,
                largeTitleFont: largeTitleFont,
                inlineTitleFont: inlineTitleFont
            )
        )
    }
}

#endif
