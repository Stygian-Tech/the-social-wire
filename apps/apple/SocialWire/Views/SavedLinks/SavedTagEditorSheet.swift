import SwiftUI

struct SavedTagEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let initialTags: [String]
    let suggestions: [String]
    let onSave: ([String]) async -> Void

    @State private var tagsText: String
    @State private var isSaving = false

    init(
        title: String,
        initialTags: [String],
        suggestions: [String],
        onSave: @escaping ([String]) async -> Void
    ) {
        self.title = title
        self.initialTags = initialTags
        self.suggestions = suggestions
        self.onSave = onSave
        _tagsText = State(initialValue: initialTags.joined(separator: ", "))
    }

    private var parsedTags: [String] {
        var seen = Set<String>()
        return tagsText.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Tags") {
                    TextField("News, Research", text: $tagsText, axis: .vertical)
                    Text("Separate tags with commas. Tag spelling and capitalization are preserved exactly.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if !suggestions.isEmpty {
                    Section("Existing Tags") {
                        ForEach(suggestions, id: \.self) { tag in
                            Button(tag) { toggle(tag) }
                                .foregroundStyle(parsedTags.contains(tag) ? Color.accentColor : Color.primary)
                        }
                    }
                }
            }
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        isSaving = true
                        Task {
                            await onSave(parsedTags)
                            isSaving = false
                            dismiss()
                        }
                    }
                    .disabled(isSaving || parsedTags.count > 100)
                }
            }
        }
    }

    private func toggle(_ tag: String) {
        var tags = parsedTags
        if let index = tags.firstIndex(of: tag) {
            tags.remove(at: index)
        } else {
            tags.append(tag)
        }
        tagsText = tags.joined(separator: ", ")
    }
}
