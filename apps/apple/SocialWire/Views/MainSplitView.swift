import SwiftUI

/// Three-column split view: folders/publications | entry list | entry detail.
/// Collapses to a navigation stack on iPhone (NavigationSplitView adapts automatically).
struct MainSplitView: View {
    @EnvironmentObject var authService: ATProtoOAuthService
    @StateObject private var viewModel = MainViewModel()

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            // Column 1: Folders + publication list
            FolderListView(viewModel: viewModel)
                .navigationTitle("The Social Wire")
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button {
                            Task { await viewModel.refreshDiscovery() }
                        } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                        .disabled(viewModel.isRefreshing)
                    }
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("Sign Out", role: .destructive) {
                            Task { await authService.signOut() }
                        }
                    }
                }

        } content: {
            // Column 2: Entry list for selected publication
            if let pub = viewModel.selectedPublication {
                EntryListView(publication: pub, viewModel: viewModel)
                    .navigationTitle(pub.title)
            } else {
                ContentUnavailableView(
                    "Select a Publication",
                    systemImage: "newspaper",
                    description: Text("Choose a publication from the sidebar.")
                )
            }

        } detail: {
            // Column 3: Entry detail
            if let entry = viewModel.selectedEntry {
                EntryDetailView(entry: entry)
            } else {
                ContentUnavailableView(
                    "Select an Entry",
                    systemImage: "doc.text",
                    description: Text("Choose an entry to read.")
                )
            }
        }
        .task {
            guard let session = authService.session else { return }
            await viewModel.load(session: session)
        }
    }
}

// ── ViewModel ─────────────────────────────────────────────────────────────────

@MainActor
final class MainViewModel: ObservableObject {
    @Published var folders: [FolderModel] = []
    @Published var publications: [PublicationModel] = []
    @Published var entries: [EntryModel] = []
    @Published var selectedPublication: PublicationModel?
    @Published var selectedEntry: EntryModel?
    @Published var isRefreshing = false
    @Published var error: Error?

    private var session: AuthSession?
    private var pdsClient: PDSClient?

    func load(session: AuthSession) async {
        self.session = session
        self.pdsClient = PDSClient(session: session)

        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.loadFolders() }
            group.addTask { await self.loadDiscovery() }
        }
    }

    func selectPublication(_ pub: PublicationModel) {
        selectedPublication = pub
        selectedEntry = nil
        Task { await loadEntries(for: pub) }
    }

    func selectEntry(_ entry: EntryModel) {
        selectedEntry = entry
    }

    func refreshDiscovery() async {
        isRefreshing = true
        defer { isRefreshing = false }
        await loadDiscovery()
    }

    // ── Private helpers ───────────────────────────────────────────────────

    private func loadFolders() async {
        do {
            folders = try await pdsClient?.listFolders() ?? []
        } catch {
            self.error = error
        }
    }

    private func loadDiscovery() async {
        guard let did = session?.did else { return }
        do {
            publications = try await pdsClient?.discoveredPublications(for: did) ?? []
        } catch {
            self.error = error
        }
    }

    private func loadEntries(for pub: PublicationModel) async {
        do {
            entries = try await pdsClient?.entries(for: pub.publicationId) ?? []
        } catch {
            self.error = error
        }
    }
}
