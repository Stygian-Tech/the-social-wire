#if os(iOS)
import SwiftUI

struct ProfileWebsiteChipView: View {
    let destination: URL

    var body: some View {
        Link(destination: destination) {
            HStack(spacing: 6) {
                Image(systemName: "globe")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .background(.fill.tertiary, in: .circle)

                Text(displayHost)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
            }
        }
        .buttonStyle(ThemeChipButtonStyle())
        .accessibilityLabel("Website, \(displayHost)")
        .accessibilityHint("Opens the website")
    }

    private var displayHost: String {
        guard var host = destination.host(), !host.isEmpty else {
            return "Website"
        }
        if host.lowercased().hasPrefix("www.") {
            host.removeFirst(4)
        }
        return host
    }
}

#endif
