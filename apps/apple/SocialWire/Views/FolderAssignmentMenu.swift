import SwiftUI

struct FolderAssignmentMenu: View {
    @Environment(SocialWireAppModel.self) private var appModel
    let publication: DiscoveredPublication

    var body: some View {
        Menu("Move to Folder", systemImage: "folder") {
            Button("No Folder") {
                Task { await appModel.assign(publication, to: nil) }
            }
            ForEach(appModel.folders) { folder in
                Button(folder.value.name) {
                    Task { await appModel.assign(publication, to: folder) }
                }
            }
        }
    }
}
