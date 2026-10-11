import SwiftUI

struct PodcastUnsubscribeConfirmation: ViewModifier {
    @Environment(PodcastLibraryModel.self) private var library
    @Binding var show: PodcastShow?
    @State private var feedback = 0

    func body(content: Content) -> some View {
        content
            .confirmationDialog("Unsubscribe from Podcast?", item: $show, titleVisibility: .visible) { show in
                Button("Unsubscribe", role: .destructive) {
                    guard let viewer = library.viewer else { return }
                    Task {
                        guard library.viewer == viewer else { return }
                        await library.unsubscribe(show)
                        if library.viewer == viewer, !library.state.subscriptions.contains(show.id), library.error == nil {
                            feedback += 1
                        }
                    }
                }
                Button("Cancel", role: .cancel) { }
            } message: { show in
                Text("\(show.title) will be removed from your subscribed podcasts.")
            }
            .onChange(of: library.viewer) { show = nil }
            .sensoryFeedback(.success, trigger: feedback)
    }
}
