import SwiftUI

struct SembleNoteEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    let initialText: String
    let onSave: (String) async -> Void
    @State private var text: String
    @State private var isSaving = false

    init(initialText: String = "", onSave: @escaping (String) async -> Void) {
        self.initialText = initialText
        self.onSave = onSave
        _text = State(initialValue: initialText)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextEditor(text: $text)
                    .frame(minHeight: 180)
                    .accessibilityLabel("Semble Note")
            }
            .navigationTitle(initialText.isEmpty ? "Add Note" : "Edit Note")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            isSaving = true
                            await onSave(text)
                            isSaving = false
                            dismiss()
                        }
                    }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
                }
            }
        }
    }
}
