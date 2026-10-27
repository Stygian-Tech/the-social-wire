#if os(iOS)
import Feeds
import SwiftUI

struct FeedManagementSheet: View {
    @Bindable var model: PinnedFeedsModel
    let openFeed: (PinnedFeed) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if model.feeds.isEmpty {
                    ContentUnavailableView(
                        "No Subscribed Feeds",
                        systemImage: "rectangle.stack",
                        description: Text("Feeds you subscribe to will appear here.")
                    )
                } else {
                    Section("Subscribed Feeds") {
                        ForEach(model.feeds) { feed in
                            Button {
                                openFeed(feed)
                            } label: {
                                HStack(spacing: 12) {
                                    FeedThumbnailView(url: feed.avatarURL)

                                    Text(feed.name)
                                        .foregroundStyle(.primary)

                                    Spacer(minLength: 0)
                                }
                                .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                        }
                        .onMove { offsets, destination in
                            Task { await model.move(fromOffsets: offsets, toOffset: destination) }
                        }
                        .onDelete { offsets in
                            Task { await model.remove(atOffsets: offsets) }
                        }
                    }
                }
            }
            .disabled(model.isUpdating)
            .navigationTitle("Manage Feeds")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    EditButton()
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("Couldn’t Update Feeds", isPresented: updateFailureBinding) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Your feed list wasn’t changed. Please try again.")
            }
        }
    }

    private var updateFailureBinding: Binding<Bool> {
        Binding(
            get: { model.updateFailed },
            set: { if !$0 { model.clearUpdateFailure() } }
        )
    }
}

#endif
