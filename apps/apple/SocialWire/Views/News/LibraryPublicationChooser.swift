import SwiftUI

struct LibraryPublicationChooser: View {
    @Environment(SocialWireAppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    @State private var showingNewFolder = false
    @State private var showingAddPublication = false
    @State private var refreshFeedback = 0

    var body: some View {
        List {
            if appModel.readerListSource == .following {
                FollowingPublicationSidebarTree(onPublicationTap: selectPublication)
            } else {
                SubscribedPublicationSidebarTree(
                    showingNewFolder: $showingNewFolder,
                    showingAddPublication: $showingAddPublication,
                    onFolderTap: { dismiss() },
                    onPublicationTap: selectPublication
                )
            }
        }
        .navigationTitle("Publications")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { dismiss() }
            }
        }
        .refreshable {
            await appModel.refreshSidebarProjection()
            refreshFeedback += 1
        }
        .sensoryFeedback(.impact(flexibility: .soft), trigger: refreshFeedback)
        .sheet(isPresented: $showingNewFolder) { NewFolderView() }
        .sheet(isPresented: $showingAddPublication) { AddPublicationView() }
        .accessibilityIdentifier("news-publications-chooser")
    }

    private func selectPublication(_ publication: DiscoveredPublication) {
        Task {
            await appModel.selectPublication(publication)
            dismiss()
        }
    }
}
