import SwiftUI

struct SembleCollectionListContent: View {
    @Environment(SocialWireAppModel.self) private var appModel
    let onItemTap: (SembleCollectionItem) -> Void
    @State private var pendingRemoval: SembleCollectionItem?
    @State private var removalFeedback = 0

    var body: some View {
        Group {
            if appModel.isLoadingSemble && appModel.sembleItems.isEmpty {
                ProgressView("Loading Collection")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if appModel.needsSembleConfiguration {
                ContentUnavailableView(
                    "Choose a Semble Collection",
                    systemImage: "square.stack.3d.up",
                    description: Text("Open Settings and choose one of the Semble collections you own.")
                )
            } else if appModel.sembleCollectionLoadFailed && appModel.sembleItems.isEmpty {
                ContentUnavailableView {
                    Label("Couldn't Load Collection", systemImage: "exclamationmark.icloud")
                } description: {
                    Text("The Semble projection is unavailable. Retry without switching to L@tr Link.")
                } actions: {
                    Button("Retry") {
                        Task { await appModel.refreshSembleCollection() }
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else if appModel.sembleItems.isEmpty {
                ContentUnavailableView(
                    "Nothing Saved Yet",
                    systemImage: "square.stack.3d.up",
                    description: Text("Save an article to add it to this Semble collection.")
                )
            } else {
                VStack(spacing: 0) {
                    if appModel.sembleCollectionLoadFailed {
                        HStack {
                            Label("Showing Cached Collection", systemImage: "exclamationmark.icloud")
                                .font(.footnote)
                            Spacer()
                            Button("Retry") {
                                Task { await appModel.refreshSembleCollection() }
                            }
                            .buttonStyle(.bordered)
                        }
                        .padding()
                        Divider()
                    }

                    List(appModel.sembleItems) { item in
                        Button {
                            onItemTap(item)
                        } label: {
                            SembleItemRow(item: item, isSelected: appModel.selectedSembleItem?.id == item.id)
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .swipeActions {
                            if item.unlinkAvailable {
                                Button("Remove", systemImage: "minus.circle", role: .destructive) {
                                    pendingRemoval = item
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                    .refreshable { await appModel.refreshSembleCollection() }
                }
            }
        }
        .confirmationDialog(
            "Remove From Collection?",
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { if !$0 { pendingRemoval = nil } }
            ),
            presenting: pendingRemoval
        ) { item in
            Button("Remove", role: .destructive) {
                Task {
                    await appModel.removeSembleItem(item)
                    removalFeedback += 1
                }
            }
        } message: { item in
            Text("This removes \"\(item.displayTitle)\" from the collection without deleting its card.")
        }
        .sensoryFeedback(.success, trigger: removalFeedback)
    }
}
