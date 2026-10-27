#if os(iOS)
import SwiftData
import SwiftUI

struct ThemeColorPickerSection: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var settings: [AppSettings]

    var body: some View {
        Section("Appearance") {
            Picker("Theme Color", selection: selection) {
                ForEach(AppThemeColor.allCases) { themeColor in
                    Label {
                        Text(themeColor.label)
                    } icon: {
                        Circle()
                            .fill(themeColor.color)
                            .frame(width: 16, height: 16)
                    }
                    .tag(themeColor)
                }
            }
            .sensoryFeedback(.selection, trigger: selectedColor)
        }
    }

    private var selectedColor: AppThemeColor {
        settings.first?.themeColor ?? .blue
    }

    private var selection: Binding<AppThemeColor> {
        Binding(
            get: { selectedColor },
            set: { themeColor in
                let appSettings: AppSettings
                if let existing = settings.first {
                    appSettings = existing
                } else {
                    appSettings = AppSettings()
                    modelContext.insert(appSettings)
                }
                appSettings.themeColor = themeColor
                try? modelContext.save()
            }
        )
    }
}

#endif
