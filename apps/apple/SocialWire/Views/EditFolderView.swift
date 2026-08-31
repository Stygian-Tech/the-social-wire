import SwiftUI

struct EditFolderView: View {
    @Environment(SocialWireAppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    let folder: RepoRecord<FolderRecord>
    @State private var name: String
    @State private var icon: String
    @State private var isSaving = false

    init(folder: RepoRecord<FolderRecord>) {
        self.folder = folder
        _name = State(initialValue: folder.value.name)
        _icon = State(initialValue: folder.value.icon ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Folder Name", text: $name)
                TextField("Icon", text: $icon)
                    .platformUncapitalizedTextInput()
            }
            .navigationTitle("Edit Folder")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            isSaving = true
                            await appModel.updateFolder(folder, name: name, icon: icon)
                            isSaving = false
                            dismiss()
                        }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
                }
            }
        }
    }
}
