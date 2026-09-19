import SwiftUI

struct SavedNewsContent: View {
    @Environment(SocialWireAppModel.self) private var appModel

    let onSavedLinkTap: (MergedLatrSave) -> Void
    let onSembleItemTap: (SembleCollectionItem) -> Void

    var body: some View {
        Group {
            if appModel.isSembleReadLaterEnabled {
                VStack(spacing: 0) {
                    if appModel.pendingSembleSaveRetry != nil {
                        HStack {
                            Label(
                                "Save Pending",
                                systemImage: "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90"
                            )
                            .font(.footnote)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityLabel("A card is waiting to be added to this collection.")
                            Spacer()
                            Button("Resume", action: resumePendingSave)
                                .buttonStyle(.borderedProminent)
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                        .padding()
                        Divider()
                    }
                    SembleCollectionListContent(onItemTap: onSembleItemTap)
                }
            } else {
                VStack(spacing: 0) {
                    SavedTagFilterBar(
                        tags: appModel.currentSavedTagCounts,
                        selection: appModel.selectedSavedTag,
                        onSelect: appModel.selectSavedTag
                    )
                    SavedLinksListContent(onSavedLinkTap: onSavedLinkTap)
                }
            }
        }
    }

    private func resumePendingSave() {
        Task { await appModel.resumeSembleSave() }
    }
}
