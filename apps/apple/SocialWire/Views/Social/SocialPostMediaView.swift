import SwiftUI

struct SocialPostMediaView: View {
    let embed: SocialEmbed

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !embed.images.isEmpty { SocialImageGrid(images: embed.images) }
            if let video = embed.video { SocialVideoPlayerView(url: video.playlist).frame(minHeight: 220) }
            if let external = embed.external { SocialStandardSiteExternalCard(embed: external) }
            if let quote = embed.quote { SocialQuotedPostCard(post: quote) }
        }
    }
}

private struct SocialImageGrid: View {
    let images: [SocialImage]
    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: images.count == 1 ? 1 : 2), spacing: 4) {
            ForEach(images) { image in
                AsyncImage(url: image.thumbnail) { phase in
                    if let loaded = phase.image { loaded.resizable().scaledToFill() }
                    else { Rectangle().fill(.secondary.opacity(0.12)) }
                }
                .frame(minHeight: images.count == 1 ? 220 : 140)
                .clipped()
                .accessibilityLabel(image.alt.isEmpty ? "Post Image" : image.alt)
            }
        }
        .clipShape(.rect(cornerRadius: 12))
    }
}

struct SocialExternalCard: View {
    let embed: SocialExternalEmbed
    @Environment(\.openURL) private var openURL
    var body: some View {
        Button { openURL(embed.uri) } label: {
            VStack(alignment: .leading, spacing: 6) {
                if let thumbnail = embed.thumbnail {
                    AsyncImage(url: thumbnail) { image in image.resizable().scaledToFill() } placeholder: { Color.secondary.opacity(0.12) }
                        .frame(height: 150).clipped()
                }
                Text(embed.title).font(.headline).lineLimit(2)
                if !embed.description.isEmpty { Text(embed.description).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(.secondary.opacity(0.08), in: .rect(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }
}

private struct SocialQuotedPostCard: View {
    let post: SocialQuotedPost
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(post.author.preferredName).font(.subheadline.weight(.semibold))
            Text("@\(post.author.handle)").font(.caption).foregroundStyle(.secondary)
            Text(post.text).font(.subheadline)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.secondary.opacity(0.08), in: .rect(cornerRadius: 12))
    }
}
