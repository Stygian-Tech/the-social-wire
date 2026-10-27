#if os(iOS)
import SwiftUI

struct NewChatView: View {
    let startConversation: @MainActor (String) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var typeahead = ActorTypeaheadModel()
    @State private var isStarting = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List(typeahead.results) { actor in
                Button {
                    isStarting = true
                    Task {
                        defer { isStarting = false }
                        do { try await startConversation(actor.did) }
                        catch { errorMessage = "This conversation couldn’t be started." }
                    }
                } label: {
                    HStack(spacing: 12) {
                        AsyncImage(url: actor.avatar) { image in image.resizable().scaledToFill() }
                            placeholder: {
                                Image(systemName: "person.crop.circle.fill")
                                    .resizable()
                                    .foregroundStyle(Color.secondary)
                            }
                            .frame(width: 42, height: 42)
                            .clipShape(.circle)
                        VStack(alignment: .leading) {
                            Text(actor.displayName ?? actor.handle)
                                .font(.headline)
                                .foregroundStyle(Color.primary)
                            Text("@\(actor.handle)")
                                .font(.subheadline)
                                .foregroundStyle(Color.secondary)
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(isStarting)
            }
            .overlay {
                if search.count >= 2, typeahead.results.isEmpty {
                    ContentUnavailableView.search(text: search)
                }
            }
            .searchable(text: $search, prompt: "Search People")
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .onChange(of: search) { _, value in typeahead.search(value) }
            .roundedNavigationTitle("New Conversation")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .alert("Unable to Start Chat", isPresented: .constant(errorMessage != nil)) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }
}

#endif
