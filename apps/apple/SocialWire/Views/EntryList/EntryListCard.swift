import SwiftUI

struct EntryListCard: View {
    let entry: EntryListItem
    let isRead: Bool
    let showsReadState: Bool
    let metadataSaveTitle: String
    let metadataSaveSystemImage: String
    let onOpen: () -> Void
    let onOpenWebsite: (() -> Void)?
    let onOpenInReader: (() -> Void)?
    let onSave: () -> Void
    let onSaveWithMetadata: () -> Void
    let onToggleRead: () -> Void
    let onAppear: () -> Void

    var body: some View {
        ArticleListCard(action: onOpen) {
            EntryRow(entry: entry, isRead: isRead, showsReadState: showsReadState)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(accessibilityValue)
        .contextMenu {
            if let onOpenWebsite {
                Button("Open on Website", systemImage: "safari", action: onOpenWebsite)
            }
            if let onOpenInReader {
                Button("Open in Native Reader", systemImage: "doc.richtext", action: onOpenInReader)
            }
            Button("Save", systemImage: "bookmark", action: onSave)
            Button(
                metadataSaveTitle,
                systemImage: metadataSaveSystemImage,
                action: onSaveWithMetadata
            )
            if showsReadState {
                Button(
                    isRead ? "Mark As Unread" : "Mark As Read",
                    systemImage: isRead ? "book.closed" : "book",
                    action: onToggleRead
                )
            }
        }
        .onAppear(perform: onAppear)
    }

    private var accessibilityValue: String {
        guard showsReadState else {
            return entry.wireMetadata?.primaryReasonLabel ?? ""
        }
        return isRead ? "Read" : "Unread"
    }
}
