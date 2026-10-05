import SwiftUI

struct SportsPostComposer: View {
    @Environment(SocialWireAppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    let entry: EntryDetail
    let isQuote: Bool
    @State private var text = ""
    @State private var isPublishing = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(entry.title).font(.headline)
                    TextEditor(text: $text).frame(minHeight: 150)
                    Text("\(text.count)/300").font(.caption).foregroundStyle(text.count > 300 ? .red : .secondary)
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle(isQuote ? "Quote Post" : "Reply")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(isPublishing) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Publish") {
                        isPublishing = true
                        Task {
                            defer { isPublishing = false }
                            do {
                                if isQuote { try await appModel.quoteEntry(entry, text: text) }
                                else { try await appModel.replyToEntry(entry, text: text) }
                                dismiss()
                            } catch { self.error = error.localizedDescription }
                        }
                    }.disabled(isPublishing || text.count > 300 || (!isQuote && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                }
            }
        }
    }
}
