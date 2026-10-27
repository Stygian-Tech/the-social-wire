#if os(iOS)
import SwiftUI

struct AnimatedImageView: View {
    private struct Request: Hashable {
        let source: AnimatedImageSource
        let firstFrameOnly: Bool
    }

    let source: AnimatedImageSource
    var contentMode: ContentMode = .fill
    var onAspectRatioLoaded: ((CGFloat) -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var frames: [AnimatedImageDecoder.Frame] = []
    @State private var totalDuration: TimeInterval = 0
    @State private var loadedSource: AnimatedImageSource?
    @State private var loadFailed = false
    @State private var isVisible = true
    @State private var loadGeneration = UUID()

    init(url: URL, contentMode: ContentMode = .fill, onAspectRatioLoaded: ((CGFloat) -> Void)? = nil) {
        source = .remote(url)
        self.contentMode = contentMode
        self.onAspectRatioLoaded = onAspectRatioLoaded
    }

    init(data: Data, contentMode: ContentMode = .fill) {
        source = .bytes(data)
        self.contentMode = contentMode
    }

    var body: some View {
        Group {
            if loadedSource != source || frames.isEmpty {
                if loadedSource == source, loadFailed {
                    ContentUnavailableView("Image Unavailable", systemImage: "photo")
                } else {
                    ProgressView()
                }
            } else if frames.count == 1 || reduceMotion || !isVisible || scenePhase != .active {
                frameImage(frames[0].image)
            } else {
                TimelineView(.animation(minimumInterval: 1 / 30)) { context in
                    frameImage(frame(at: context.date).image)
                }
            }
        }
        .task(id: Request(source: source, firstFrameOnly: reduceMotion)) { await load() }
        .onScrollVisibilityChange(threshold: 0.1) { isVisible = $0 }
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false }
    }

    @ViewBuilder
    private func frameImage(_ image: CGImage) -> some View {
        let view = Image(decorative: image, scale: 1).resizable()
        if contentMode == .fill {
            view.scaledToFill()
        } else {
            view.scaledToFit()
        }
    }

    private func frame(at date: Date) -> AnimatedImageDecoder.Frame {
        guard totalDuration > 0 else { return frames[0] }
        var elapsed = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: totalDuration)
        for frame in frames {
            if elapsed < frame.duration { return frame }
            elapsed -= frame.duration
        }
        return frames[0]
    }

    private func load() async {
        let generation = UUID()
        loadGeneration = generation
        frames = []
        totalDuration = 0
        loadedSource = source
        loadFailed = false
        do {
            let result = try await AnimatedImageDecoder.shared.load(source, firstFrameOnly: reduceMotion)
            try Task.checkCancellation()
            guard loadGeneration == generation else { return }
            frames = result.frames
            totalDuration = result.duration
            if let image = result.frames.first?.image {
                onAspectRatioLoaded?(CGFloat(image.width) / CGFloat(image.height))
            }
        } catch {
            guard !Task.isCancelled, loadGeneration == generation else { return }
            loadFailed = true
        }
    }
}

#endif
