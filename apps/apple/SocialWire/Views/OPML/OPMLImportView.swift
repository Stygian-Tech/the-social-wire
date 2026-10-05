import SwiftUI
import UniformTypeIdentifiers

struct OPMLImportView: View {
    @Environment(SocialWireAppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    @State private var model = OPMLImportModel()
    @State private var showingImporter = false
    @State private var destination: OPMLImportDestination
    @State private var privateFeeds = false
    @State private var refreshingExisting = false

    init(initialDestination: OPMLImportDestination = .publications) {
        _destination = State(initialValue: initialDestination)
    }

    private var selectionIdentity: String {
        "\(appModel.viewerDID ?? "")|\(destination.rawValue)|\(privateFeeds)"
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Import To", selection: $destination) {
                        ForEach(OPMLImportDestination.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    if destination == .podcasts { Toggle("Private Feeds", isOn: $privateFeeds) }
                } footer: {
                    Text(destination == .podcasts
                         ? (privateFeeds ? "Private podcast feeds stay in your account. No public PDS subscriptions are created." : "Import audio podcast feeds. Select Private Feeds for subscriber-only or credential-bearing URLs.")
                         : "Import RSS or Atom publications into your reading library.")
                }
                .disabled(model.isImporting || refreshingExisting)
                if refreshingExisting { ProgressView("Checking Existing Subscriptions") }
                if model.feeds.isEmpty {
                    ContentUnavailableView(
                        "Choose an OPML File",
                        systemImage: "doc.badge.plus",
                        description: Text("Review discovered feeds before anything is added to your Library.")
                    )
                } else {
                    Section("Feeds") {
                        ForEach(model.feeds) { feed in
                            Toggle(isOn: selectionBinding(for: feed)) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(feed.title)
                                    Text(destination == .podcasts && privateFeeds ? (URL(string: feed.feedURL)?.host ?? "Private Feed") : feed.feedURL)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            .disabled(model.existingFeedURLs.contains(feed.feedURL) || model.isImporting)
                            .accessibilityHint(
                                model.existingFeedURLs.contains(feed.feedURL)
                                    ? "Already subscribed"
                                    : "Select this feed for import"
                            )
                        }
                    }

                    if model.isImporting {
                        Section("Importing") {
                            ProgressView(
                                value: Double(model.completedCount),
                                total: Double(max(model.totalCount, 1))
                            )
                            Text("\(model.completedCount) of \(model.totalCount)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if !model.failures.isEmpty {
                        Section("Needs Attention") {
                            ForEach(model.failures) { failure in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(failure.feed.title)
                                    Text(failure.message)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Button("Retry Failed Feeds") {
                                importFeeds(model.failures.map(\.feed))
                            }
                            .disabled(model.isImporting)
                        }
                    }
                }
            }
            .interactiveDismissDisabled(model.isImporting)
            .navigationTitle("Import OPML")
            .task(id: selectionIdentity) { await refreshExisting() }
            .onChange(of: appModel.viewerDID) { _, _ in model.clear() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }.disabled(model.isImporting)
                }
                ToolbarItemGroup(placement: .confirmationAction) {
                    Button("Choose File") { showingImporter = true }.disabled(model.isImporting || refreshingExisting)
                    if !model.feeds.isEmpty {
                        Button("Import") { importFeeds(model.selectedFeeds) }
                            .disabled(model.selectedFeeds.isEmpty || model.isImporting || refreshingExisting)
                    }
                }
            }
            .fileImporter(
                isPresented: $showingImporter,
                allowedContentTypes: [.xml, .data],
                allowsMultipleSelection: false
            ) { result in
                Task { await loadFile(result) }
            }
            .alert(
                "Could Not Import OPML",
                isPresented: Binding(
                    get: { model.errorMessage != nil },
                    set: { if !$0 { model.errorMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) { model.errorMessage = nil }
            } message: {
                Text(model.errorMessage ?? "Unknown error")
            }
        }
    }

    private func selectionBinding(for feed: OPMLFeed) -> Binding<Bool> {
        Binding(
            get: { model.selectedFeedURLs.contains(feed.feedURL) },
            set: { isSelected in
                if isSelected {
                    model.selectedFeedURLs.insert(feed.feedURL)
                } else {
                    model.selectedFeedURLs.remove(feed.feedURL)
                }
            }
        )
    }

    private func loadFile(_ result: Result<[URL], Error>) async {
        do {
            guard let url = try result.get().first else { return }
            let hasAccess = url.startAccessingSecurityScopedResource()
            defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            if let fileSize = values.fileSize, fileSize > OPMLParser.maximumBytes {
                throw OPMLParserError.fileTooLarge
            }
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            let identity = selectionIdentity
            let existing = try await existingURLs()
            guard selectionIdentity == identity else { return }
            model.load(data: data, existingFeedURLs: existing)
        } catch {
            model.errorMessage = error.localizedDescription
        }
    }

    private func importFeeds(_ feeds: [OPMLFeed]) {
        guard !feeds.isEmpty, let viewer = appModel.viewerDID else { return }
        let destination = destination
        let privateFeeds = privateFeeds
        model.beginImport(total: feeds.count)
        Task {
            guard appModel.viewerDID == viewer else { return }
            let failures: [OPMLImportFailure]
            if destination == .podcasts {
                failures = await appModel.podcasts.importOPMLFeeds(feeds, privateFeeds: privateFeeds, currentViewer: { appModel.viewerDID }) { completed, _ in
                    if appModel.viewerDID == viewer { model.noteProgress(completed) }
                }
            } else {
                failures = await appModel.importOPMLFeeds(feeds) { completed, _ in
                    if appModel.viewerDID == viewer { model.noteProgress(completed) }
                }
            }
            guard appModel.viewerDID == viewer else { return }
            let failedURLs = Set(failures.map { $0.feed.feedURL })
            let succeeded = Set(feeds.map(\.feedURL)).subtracting(failedURLs)
            model.finishImport(failures: failures, successfulFeedURLs: succeeded)
        }
    }

    private func existingURLs() async throws -> Set<String> {
        if destination == .podcasts { return try await appModel.podcasts.existingOPMLFeedURLs(privateFeeds: privateFeeds) }
        return await appModel.existingSkyreaderFeedURLs()
    }

    private func refreshExisting() async {
        let identity = selectionIdentity
        refreshingExisting = true
        defer { if selectionIdentity == identity { refreshingExisting = false } }
        do {
            let urls = try await existingURLs()
            guard !Task.isCancelled, selectionIdentity == identity, !model.isImporting else { return }
            model.updateExistingFeedURLs(urls)
        } catch is CancellationError { } catch {
            guard selectionIdentity == identity else { return }
            model.errorMessage = "Could Not Check Existing Subscriptions. Retry Before Importing."
        }
    }

}
