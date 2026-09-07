import SwiftUI

struct PublicationSearchView: View {
    @Environment(SocialWireAppModel.self) private var appModel

    let query: String

    @State private var result: ResolveAddPublicationResultDTO?
    @State private var isResolving = false
    @State private var isAdding = false
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Find Publications")
                        .font(.largeTitle.bold())
                    Text("Search by website, feed URL, handle, DID, or publication AT-URI.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }

                if isResolving {
                    ProgressView("Resolving Publication")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let result {
                    PublicationResolutionPreviewView(
                        result: result,
                        isSubscribed: appModel.isSubscribed(to: result),
                        isAdding: isAdding,
                        onAdd: add
                    )
                }

                if let errorMessage {
                    ContentUnavailableView(
                        "Publication Not Found",
                        systemImage: "magnifyingglass",
                        description: Text(errorMessage)
                    )
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Publisher-first discovery", systemImage: "safari")
                            .font(.headline)
                        Text("Search resolves a publication or feed without indexing its articles. Source links continue to lead to the publisher's website.")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                }
            }
            .frame(maxWidth: 720, alignment: .leading)
            .padding()
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .navigationTitle("Search")
        .task(id: normalizedQuery) {
            await resolve()
        }
    }

    private var normalizedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func resolve() async {
        guard !normalizedQuery.isEmpty else { return }
        isResolving = true
        result = nil
        errorMessage = nil
        defer { isResolving = false }
        do {
            result = try await appModel.resolvePublication(input: normalizedQuery)
        } catch {
            result = nil
            errorMessage = error.localizedDescription
        }
    }

    private func add() {
        guard let result else { return }
        Task {
            isAdding = true
            errorMessage = nil
            defer { isAdding = false }
            do {
                try await appModel.addResolvedPublication(result)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
