#if os(iOS)
import Feeds
import SwiftUI

struct StoryViewerView: View {
    let stories: StoryModel
    let onStorySeen: (StoryRecord) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var playback: StoryPlayback
    @State private var timerGeneration = 0
    @State private var navigationFeedback = 0
    @State private var progress = 0.0
    @State private var isCreatingStory = false
    @State private var creationFeedback = 0

    init(
        items: [StoryFeedItem],
        startingAuthorID: String,
        stories: StoryModel,
        onStorySeen: @escaping (StoryRecord) -> Void
    ) {
        self.stories = stories
        self.onStorySeen = onStorySeen
        _playback = State(initialValue: StoryPlayback(items: items, startingAuthorID: startingAuthorID))
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()

            TabView(selection: Binding(
                get: { playback.current?.id ?? "" },
                set: { playback.select(id: $0); timerGeneration += 1 }
            )) {
                ForEach(playback.pages) { page in
                    StoryPageView(author: page.author, story: page.story)
                        .overlay {
                            HStack(spacing: 0) {
                                Button { previous() } label: { Color.clear.contentShape(Rectangle()) }
                                    .accessibilityLabel("Previous Story")
                                Button { advanceToNextStory() } label: { Color.clear.contentShape(Rectangle()) }
                                    .accessibilityLabel("Next Story")
                            }
                            .buttonStyle(.plain)
                            .padding(.top, 80)
                        }
                        .tag(page.id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

            VStack(spacing: 10) {
                progressBar
                header
                    .padding(.horizontal)
            }
            .padding(.top, 8)
        }
        .sensoryFeedback(.selection, trigger: navigationFeedback)
        .sensoryFeedback(.impact, trigger: creationFeedback)
        .preferredColorScheme(.dark)
        .fullScreenCover(isPresented: $isCreatingStory) {
            StoryComposerView(stories: stories, startsWithCamera: true)
        }
        .onAppear { markSelectedStorySeen() }
        .onChange(of: playback.current?.id) { _, _ in markSelectedStorySeen() }
        .task(id: "\(timerGeneration)-\(scenePhase)") {
            guard scenePhase == .active else { return }
            await runTimer()
        }
    }

    private var progressBar: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(.white.opacity(0.3))

                Rectangle()
                    .fill(.white)
                    .frame(width: geometry.size.width * progress)
            }
        }
        .frame(height: 2)
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack(alignment: .bottomTrailing) {
                AsyncImage(url: playback.current?.author.avatarURL) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Image(systemName: "person.fill")
                        .foregroundStyle(.secondary)
                }
                .frame(width: 34, height: 34)
                .background(.fill.tertiary, in: .circle)
                .clipShape(.circle)

                if playback.current?.isCurrentUser == true, stories.canPublish {
                    Button("Add to Your Story", systemImage: "plus.circle.fill") {
                        isCreatingStory = true
                        creationFeedback += 1
                    }
                    .labelStyle(.iconOnly)
                    .font(.body)
                    .foregroundStyle(.white, .blue)
                    .buttonStyle(.plain)
                    .offset(x: 5, y: 5)
                }
            }

            Text(playback.current?.author.displayName ?? playback.current?.author.handle ?? "Story")
                .font(.headline)
                .lineLimit(1)

            Spacer()

            Button("Close", systemImage: "xmark") { dismiss() }
                .labelStyle(.iconOnly)
                .buttonStyle(.bordered)
                .buttonBorderShape(.circle)
        }
    }

    private func markSelectedStorySeen() {
        guard let story = playback.current?.story else { return }
        onStorySeen(story)
    }

    private func runTimer() async {
        progress = 0
        await Task.yield()

        withAnimation(.linear(duration: 8)) {
            progress = 1
        }

        try? await Task.sleep(for: .seconds(8))
        guard !Task.isCancelled else { return }
        advanceToNextStory()
    }

    private func previous() {
        playback.previous()
        timerGeneration += 1
        navigationFeedback += 1
    }

    private func advanceToNextStory() {
        guard playback.next() else { dismiss(); return }
        timerGeneration += 1
        navigationFeedback += 1
    }
}

#endif
