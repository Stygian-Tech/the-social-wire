#if os(iOS)
import SwiftData
import SwiftUI

struct VideoPlaybackSettingsSection: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var settings: [AppSettings]
    @State private var saveFailed = false

    var body: some View {
        Section("Playback") {
            Picker("Video Playback", selection: preference) {
                ForEach(VideoPlaybackPolicy.allCases) { policy in
                    Text(policy.title).tag(policy)
                }
            }
            .sensoryFeedback(.selection, trigger: settings.first?.videoPlaybackPolicy ?? .tapToPlay)
        }
        .alert("Couldn’t Save Playback Preference", isPresented: $saveFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Please try again.")
        }
    }

    private var preference: Binding<VideoPlaybackPolicy> {
        Binding(
            get: { settings.first?.videoPlaybackPolicy ?? .tapToPlay },
            set: { value in
                let setting = settings.first ?? AppSettings()
                if settings.first == nil { modelContext.insert(setting) }
                let previous = setting.videoPlaybackPolicy
                setting.videoPlaybackPolicy = value
                do {
                    try modelContext.save()
                } catch {
                    setting.videoPlaybackPolicy = previous
                    saveFailed = true
                }
            }
        )
    }
}

#endif
