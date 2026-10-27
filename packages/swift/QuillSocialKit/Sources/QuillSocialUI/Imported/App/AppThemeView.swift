#if os(iOS)
import SwiftData
import SwiftUI

struct AppThemeView<Content: View>: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var settings: [AppSettings]

    private let accentColor: Color
    private let content: Content

    init(accentColor: Color, @ViewBuilder content: () -> Content) {
        self.accentColor = accentColor
        self.content = content()
    }

    var body: some View {
        content
            // The host owns appearance. Keep system controls and imported accent shapes in sync.
            .tint(accentColor)
            .accentColor(accentColor)
            .task {
                guard settings.isEmpty else { return }
                modelContext.insert(AppSettings())
                try? modelContext.save()
            }
    }
}

#endif
