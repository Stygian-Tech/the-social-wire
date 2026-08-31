import SwiftUI

struct SavedTagManagementView: View {
    @Environment(SocialWireAppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    @State private var pendingRename: String?
    @State private var replacement = ""
    @State private var pendingDelete: String?

    var body: some View {
        NavigationStack {
            List {
                if let progress = appModel.savedTagMutationProgress {
                    Section("Progress") {
                        if appModel.isMutatingSavedTags { ProgressView() }
                        Text("Scanned \(progress.scanned), matched \(progress.matched), updated \(progress.updated)")
                            .font(.footnote)
                        if let message = progress.errorMessage {
                            Text(message).foregroundStyle(.red)
                            Button("Resume") { Task { await appModel.resumeSavedTagMutation() } }
                        } else if progress.isComplete {
                            Label("Complete", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                        if !appModel.isMutatingSavedTags {
                            Button("Dismiss Progress") { appModel.dismissSavedTagMutationProgress() }
                        }
                    }
                }

                Section("Tags") {
                    ForEach(appModel.currentSavedTagCounts) { item in
                        HStack {
                            Text(item.tag)
                            Spacer()
                            Text("\(item.count)").foregroundStyle(.secondary)
                            Menu {
                                Button("Rename") {
                                    pendingRename = item.tag
                                    replacement = item.tag
                                }
                                Button("Delete", role: .destructive) {
                                    pendingDelete = item.tag
                                }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                            }
                        }
                    }
                }
            }
            .navigationTitle("Manage Tags")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .alert("Rename Tag", isPresented: Binding(
            get: { pendingRename != nil },
            set: { if !$0 { pendingRename = nil } }
        )) {
            TextField("Replacement", text: $replacement)
            Button("Rename") {
                guard let tag = pendingRename else { return }
                let next = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
                pendingRename = nil
                guard !next.isEmpty, next != tag else { return }
                Task { await appModel.renameSavedTag(tag, replacement: next) }
            }
            Button("Cancel", role: .cancel) { pendingRename = nil }
        } message: {
            Text("This renames the tag on every matching L@tr bookmark.")
        }
        .confirmationDialog(
            "Delete this tag everywhere?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { tag in
            Button("Delete \"\(tag)\"", role: .destructive) {
                pendingDelete = nil
                Task { await appModel.deleteSavedTag(tag) }
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        }
    }
}
