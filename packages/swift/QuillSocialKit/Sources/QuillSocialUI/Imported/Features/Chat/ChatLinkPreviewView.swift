#if os(iOS)
import SwiftUI

struct ChatLinkPreviewView: View {
    let url: URL

    var body: some View {
        Link(destination: url) {
            HStack(spacing: 10) {
                Image(systemName: "link")
                    .font(.title3)
                    .frame(width: 28, height: 28)
                    .background(.fill.tertiary, in: .rect(cornerRadius: 7))

                VStack(alignment: .leading, spacing: 2) {
                    Text(displayHost)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(url.absoluteString)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                }

                Spacer(minLength: 0)

                Image(systemName: "arrow.up.forward.app")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(8)
            .background(.background.opacity(0.7), in: .rect(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(.separator, lineWidth: 0.5)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens the link")
    }

    private var displayHost: String {
        guard var host = url.host(), !host.isEmpty else { return "Link" }
        if host.lowercased().hasPrefix("www.") {
            host.removeFirst(4)
        }
        return host
    }
}

#endif
