import SwiftUI

struct PublicationResolutionPreviewView: View {
    let result: ResolveAddPublicationResultDTO
    let isSubscribed: Bool
    let isAdding: Bool
    var showsAddButton = true
    let onAdd: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                CachedRemoteImage(urls: iconURLs, maxPixelSize: 128) {
                    Image(systemName: result.kind == "rss" ? "dot.radiowaves.left.and.right" : "newspaper")
                        .foregroundStyle(.secondary)
                }
                .scaledToFill()
                .frame(width: 54, height: 54)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Text(result.title ?? fallbackTitle)
                        .font(.title3.bold())
                    Text(result.kind == "rss" ? "RSS or Atom Feed" : "standard.site Publication")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if let sourceLabel {
                        Text(sourceLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let websiteURL {
                Link(destination: websiteURL) {
                    Label("Open Publisher Website", systemImage: "safari")
                }
                .buttonStyle(.bordered)
            }

            if isSubscribed {
                Label("Already Subscribed", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.secondary)
            } else if showsAddButton {
                Button(action: onAdd) {
                    if isAdding {
                        ProgressView()
                            .accessibilityLabel("Adding Publication")
                    } else {
                        Label("Add Publication", systemImage: "plus.circle.fill")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isAdding)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    private var iconURLs: [URL] {
        [result.feedIconUrl, result.siteUrl]
            .compactMap { $0.flatMap(URL.init(string:)) }
    }

    private var websiteURL: URL? {
        result.siteUrl.flatMap(URL.init(string:))
    }

    private var sourceLabel: String? {
        result.siteUrl ?? result.feedUrl ?? result.publicationAtUri
    }

    private var fallbackTitle: String {
        if let siteUrl = result.siteUrl, let host = URL(string: siteUrl)?.host {
            return host
        }
        return "Publication"
    }
}
