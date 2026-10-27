#if os(iOS)
import SwiftData
import SwiftUI

struct AccessibilitySettingsSection: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var settings: [AppSettings]

    var body: some View {
        Section {
            Toggle("Require Alt Text", isOn: requiresAltText)
                .sensoryFeedback(.selection, trigger: settings.first?.requiresAltText ?? false)
            Toggle("Generate Alt Text in Composer", isOn: allowsComposerGeneration)
                .sensoryFeedback(
                    .selection,
                    trigger: settings.first?.allowsComposerAltTextGeneration ?? true
                )
            Toggle("Generate Alt Text in Image Viewer", isOn: allowsViewerGeneration)
                .sensoryFeedback(
                    .selection,
                    trigger: settings.first?.allowsViewerAltTextGeneration ?? true
                )
        } header: {
            Text("Accessibility")
        } footer: {
            Text("Require image descriptions before posting and control where on-device descriptions can be generated.")
        }
    }

    private var requiresAltText: Binding<Bool> {
        Binding(
            get: { settings.first?.requiresAltText ?? false },
            set: { newValue in
                let appSettings: AppSettings
                if let existing = settings.first {
                    appSettings = existing
                } else {
                    appSettings = AppSettings()
                    modelContext.insert(appSettings)
                }
                appSettings.requiresAltText = newValue
                try? modelContext.save()
            }
        )
    }

    private var allowsComposerGeneration: Binding<Bool> {
        settingBinding(\.allowsComposerAltTextGeneration, default: true)
    }

    private var allowsViewerGeneration: Binding<Bool> {
        settingBinding(\.allowsViewerAltTextGeneration, default: true)
    }

    private func settingBinding(
        _ keyPath: ReferenceWritableKeyPath<AppSettings, Bool>,
        default defaultValue: Bool
    ) -> Binding<Bool> {
        Binding(
            get: { settings.first?[keyPath: keyPath] ?? defaultValue },
            set: { newValue in
                let appSettings = settings.first ?? AppSettings()
                if settings.first == nil { modelContext.insert(appSettings) }
                appSettings[keyPath: keyPath] = newValue
                try? modelContext.save()
            }
        )
    }
}

#endif
