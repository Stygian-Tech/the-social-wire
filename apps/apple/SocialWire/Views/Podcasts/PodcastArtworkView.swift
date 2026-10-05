import SwiftUI

struct PodcastArtworkView: View {
    @Environment(PodcastLibraryModel.self) private var library
    let url: String?
    var size: CGFloat = 48
    @State private var privateData: Data?
    @State private var loadedIdentity: PodcastArtworkIdentity?

    var body: some View {
        let identity = PodcastArtworkIdentity(viewer: library.viewer, url: url)
        Group {
            if loadedIdentity == identity, let privateData {
#if os(iOS)
                if let image = UIImage(data: privateData) { Image(uiImage: image).resizable().scaledToFill() }
#else
                if let image = NSImage(data: privateData) { Image(nsImage: image).resizable().scaledToFill() }
#endif
            } else if let url, !url.hasPrefix("/v1/podcasts/"), let remote = URL(string: url), remote.scheme == "https" {
                AsyncImage(url: remote) { image in image.resizable().scaledToFill() } placeholder: { placeholder }
            } else { placeholder }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityHidden(true)
        .task(id: identity) {
            privateData = nil
            loadedIdentity = nil
            guard let url else { return }
            let data = await library.artworkData(url)
            guard !Task.isCancelled, identity == PodcastArtworkIdentity(viewer: library.viewer, url: self.url) else { return }
            loadedIdentity = identity
            privateData = data
        }
    }

    private var placeholder: some View {
        Image(systemName: "headphones").resizable().scaledToFit().padding(size / 4).background(.quaternary)
    }
}
