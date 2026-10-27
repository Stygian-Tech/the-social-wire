#if os(iOS)
import ATProtoCore
import Navigation
import SwiftUI

struct QuillSocialListsView: View {
    struct ListSummary: Decodable, Identifiable {
        struct Creator: Decodable { let did: String }
        let uri: String
        let name: String
        let description: String?
        let avatar: URL?
        let creator: Creator
        let listItemCount: Int?
        var id: String { uri }
    }

    private struct Response: Decodable { let lists: [ListSummary]; let cursor: String? }

    let configuration: QuillSocialConfiguration
    @Environment(AppServices.self) private var services
    @Environment(\.routeNavigator) private var navigator
    @State private var lists: [ListSummary] = []
    @State private var cursor: String?
    @State private var seenCursors: Set<String> = []
    @State private var isLoading = false
    @State private var hasLoaded = false
    @State private var errorMessage: String?
    @State private var actionError: String?
    @State private var editingList: ListSummary?
    @State private var showsEditor = false
    @State private var deletingList: ListSummary?
    @State private var feedback = 0

    var body: some View {
        List {
            ForEach(lists) { list in
                Button {
                    guard let uri = try? ATURI(list.uri) else { return }
                    navigator?(.list(uri))
                } label: {
                    HStack(spacing: 12) {
                        AsyncImage(url: list.avatar) { $0.resizable().scaledToFill() } placeholder: {
                            Image(systemName: "list.bullet.rectangle").resizable().scaledToFit().padding(10)
                        }
                        .frame(width: 44, height: 44).clipShape(.rect(cornerRadius: 8))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(list.name).font(.headline)
                            if let description = list.description, !description.isEmpty {
                                Text(description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                            Text("\(list.listItemCount ?? 0) Members").font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(.primary).contentShape(.rect)
                }
                .buttonStyle(.plain)
                .swipeActions {
                    if list.creator.did == configuration.viewerDID {
                        Button("Edit", systemImage: "pencil") { editingList = list; showsEditor = true }
                        Button("Delete", systemImage: "trash", role: .destructive) { deletingList = list }
                    }
                }
            }
            if isLoading {
                ProgressView().frame(maxWidth: .infinity)
            } else if let errorMessage {
                VStack {
                    Text(errorMessage).foregroundStyle(.secondary)
                    Button("Try Again") { Task { await load(reset: lists.isEmpty) } }
                }
            } else if cursor != nil {
                Color.clear.frame(height: 1).task(id: cursor) { await load(reset: false) }
            }
        }
        .listStyle(.plain)
        .roundedNavigationTitle("Lists")
        .overlay {
            if hasLoaded && lists.isEmpty && !isLoading && errorMessage == nil {
                ContentUnavailableView("No Lists Yet", systemImage: "list.bullet", description: Text("Create a list to organize people and their posts."))
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("New List", systemImage: "plus") { editingList = nil; showsEditor = true }
            }
        }
        .task { if !hasLoaded { await load(reset: true) } }
        .refreshable { await load(reset: true) }
        .sensoryFeedback(.success, trigger: feedback)
        .sheet(isPresented: $showsEditor) {
            QuillSocialListEditorView(list: editingList) { name, description, member in
                try await save(editingList, name: name, description: description, member: member)
            }
        }
        .confirmationDialog("Delete This List?", isPresented: Binding(
            get: { deletingList != nil }, set: { if !$0 { deletingList = nil } }
        ), titleVisibility: .visible) {
            Button("Delete List", role: .destructive) {
                guard let list = deletingList else { return }
                deletingList = nil
                Task { await delete(list) }
            }
        }
        .alert("List Update Failed", isPresented: Binding(
            get: { actionError != nil }, set: { if !$0 { actionError = nil } }
        )) { Button("OK") { actionError = nil } } message: { Text(actionError ?? "") }
    }

    private func load(reset: Bool) async {
        guard !isLoading else { return }
        let requestedCursor = reset ? nil : cursor
        guard reset || requestedCursor != nil else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            var parameters = ["actor": configuration.viewerDID, "limit": "100"]
            parameters["cursor"] = requestedCursor
            let data = try await services.appViewRequest("app.bsky.graph.getLists", parameters)
            try Task.checkCancellation()
            let response = try JSONDecoder().decode(Response.self, from: data)
            if reset { lists = []; seenCursors = [] }
            var known = Set(lists.map(\.uri))
            lists.append(contentsOf: response.lists.filter { known.insert($0.uri).inserted })
            if let requestedCursor { seenCursors.insert(requestedCursor) }
            cursor = response.cursor.flatMap { $0.isEmpty || seenCursors.contains($0) ? nil : $0 }
            hasLoaded = true
        } catch is CancellationError {
        } catch { errorMessage = error.localizedDescription }
    }

    private func save(_ list: ListSummary?, name: String, description: String, member: String) async throws {
        let uri: String
        if let list {
            let rkey = try recordKey(list)
            let existing = try await configuration.pdsRequest("com.atproto.repo.getRecord", [
                "repo": configuration.viewerDID, "collection": "app.bsky.graph.list", "rkey": rkey
            ])
            guard let object = try JSONSerialization.jsonObject(with: existing) as? [String: Any],
                  var record = object["value"] as? [String: Any] else { throw URLError(.cannotParseResponse) }
            record["name"] = name
            record["description"] = description
            var body: [String: Any] = ["repo": configuration.viewerDID, "collection": "app.bsky.graph.list", "rkey": rkey, "record": record]
            if let cid = object["cid"] as? String { body["swapRecord"] = cid }
            _ = try await configuration.pdsProcedure("com.atproto.repo.putRecord", JSONSerialization.data(withJSONObject: body))
            uri = list.uri
        } else {
            let body: [String: Any] = [
                "repo": configuration.viewerDID, "collection": "app.bsky.graph.list",
                "record": ["$type": "app.bsky.graph.list", "purpose": "app.bsky.graph.defs#curatelist",
                           "name": name, "description": description, "createdAt": Date().ISO8601Format()]
            ]
            let result = try await configuration.pdsProcedure("com.atproto.repo.createRecord", JSONSerialization.data(withJSONObject: body))
            guard let object = try JSONSerialization.jsonObject(with: result) as? [String: Any],
                  let createdURI = object["uri"] as? String else { throw URLError(.cannotParseResponse) }
            uri = createdURI
        }
        let member = member.trimmingCharacters(in: .whitespacesAndNewlines)
        if !member.isEmpty {
            let did = try DID(member)
            let body: [String: Any] = [
                "repo": configuration.viewerDID, "collection": "app.bsky.graph.listitem",
                "record": ["$type": "app.bsky.graph.listitem", "list": uri, "subject": did.description, "createdAt": Date().ISO8601Format()]
            ]
            _ = try await configuration.pdsProcedure("com.atproto.repo.createRecord", JSONSerialization.data(withJSONObject: body))
        }
        feedback += 1
        await load(reset: true)
    }

    private func delete(_ list: ListSummary) async {
        do {
            let body = ["repo": configuration.viewerDID, "collection": "app.bsky.graph.list", "rkey": try recordKey(list)]
            _ = try await configuration.pdsProcedure("com.atproto.repo.deleteRecord", JSONSerialization.data(withJSONObject: body))
            lists.removeAll { $0.uri == list.uri }
            feedback += 1
        } catch { actionError = error.localizedDescription }
    }

    private func recordKey(_ list: ListSummary) throws -> String {
        guard list.creator.did == configuration.viewerDID,
              let uri = try? ATURI(list.uri), uri.authority.description == configuration.viewerDID,
              let rkey = uri.recordKey else { throw URLError(.noPermissionsToReadFile) }
        return rkey.description
    }
}
#endif
