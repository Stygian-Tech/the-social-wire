#if os(iOS)
import SwiftUI

/// Stands in for the pinned feeds list when there's nothing to show. "Couldn't load" and
/// "nothing pinned" read very differently, so they're worded separately.
struct PinnedFeedsEmptyLabel: View {
    let didFail: Bool

    var body: some View {
        Group {
            if didFail {
                Label("Couldn't Load Feeds", systemImage: "exclamationmark.triangle")
            } else {
                Label("No Pinned Feeds", systemImage: "pin.slash")
            }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
    }
}

#endif
