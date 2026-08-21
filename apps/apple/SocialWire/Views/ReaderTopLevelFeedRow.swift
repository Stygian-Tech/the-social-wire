import SwiftUI

struct ReaderTopLevelFeedRow: View {
    @Environment(SocialWireAppModel.self) private var appModel
    let source: ReaderListSource
    let onSelect: () -> Void
    @State private var showMarkReadConfirm = false
    @State private var markReadFeedback = 0

    var body: some View {
        Group {
            if source.supportsMarkAllReadContextMenu {
                feedButton
                    .contextMenu {
                        Button("Mark All As Read", systemImage: "checkmark.circle") {
                            showMarkReadConfirm = true
                        }
                        .disabled(appModel.isMarkReadDisabled(for: .list(source)))
                    }
            } else {
                feedButton
            }
        }
        .alert("Mark All As Read?", isPresented: $showMarkReadConfirm) {
            Button("Mark All As Read") {
                Task {
                    await appModel.markRead(for: .list(source))
                    markReadFeedback += 1
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(confirmationMessage)
        }
        .sensoryFeedback(.success, trigger: markReadFeedback)
    }

    private var feedButton: some View {
        Button(action: onSelect) {
            HStack {
                Image(systemName: source.systemImage)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(displayTitle)
                    if let subtitle = displaySubtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                if appModel.showsTopLevelFeedUnreadCount(for: source) {
                    SidebarCountLabel(
                        count: appModel.topLevelUnreadCount(for: source),
                        accessibilityDescription: "unread articles"
                    )
                }
                if appModel.isTopLevelFeedSelected(source) {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.accentColor)
                        .accessibilityHidden(true)
                }
            }
            .readerFullWidthTapLabel()
        }
        .buttonStyle(.plain)
        .readerClearListRow()
        .accessibilityAddTraits(appModel.isTopLevelFeedSelected(source) ? .isSelected : [])
    }

    private var confirmationMessage: String {
        switch source {
        case .wire:
            ""
        case .subscribed:
            "This marks every unread article in Subscribed as read."
        case .following:
            "This marks every unread article in Following as read."
        case .readLater, .archive:
            ""
        }
    }

    private var displayTitle: String {
        return source.rawValue
    }

    private var displaySubtitle: String? {
        return source.navigationSubtitle
    }
}
