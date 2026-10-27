#if os(iOS)
import SwiftUI

struct QuillSocialListEditorView: View {
    @Environment(\.dismiss) private var dismiss
    private let list: QuillSocialListsView.ListSummary?
    private let save: (String, String, String) async throws -> Void
    @State private var name: String
    @State private var description: String
    @State private var member = ""
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(list: QuillSocialListsView.ListSummary?, save: @escaping (String, String, String) async throws -> Void) {
        self.list = list
        self.save = save
        _name = State(initialValue: list?.name ?? "")
        _description = State(initialValue: list?.description ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                TextField("Description", text: $description, axis: .vertical)
                if list != nil {
                    TextField("Add Member DID", text: $member)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            }
            .navigationTitle(list == nil ? "New List" : "Edit List")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(isSaving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        isSaving = true
                        errorMessage = nil
                        Task {
                            do {
                                try await save(name.trimmingCharacters(in: .whitespacesAndNewlines), description, member)
                                dismiss()
                            } catch { errorMessage = error.localizedDescription }
                            isSaving = false
                        }
                    }
                    .disabled(isSaving || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .interactiveDismissDisabled(isSaving)
    }
}
#endif
