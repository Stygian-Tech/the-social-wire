import SwiftUI

struct FeedDisplayPicker: View {
    let title: String
    let supportsCount: Bool
    let canHide: Bool
    @Binding var selection: FeedDisplayOption

    private var options: [FeedDisplayOption] {
        supportsCount
            ? [.showFeedAndCount, .showFeedOnly, .hideFeed]
            : [.showFeedOnly, .hideFeed]
    }

    var body: some View {
        Picker(title, selection: $selection) {
            ForEach(options) { option in
                Text(displayTitle(for: option))
                    .tag(option)
                    .disabled(option == .hideFeed && !canHide)
            }
        }
    }

    private func displayTitle(for option: FeedDisplayOption) -> String {
        guard !supportsCount, option == .showFeedOnly else {
            return option.title
        }
        return "Show Feed"
    }
}
