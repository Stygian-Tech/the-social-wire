#if os(iOS)
import ATProtoCore
import Navigation
import SwiftUI

struct QuillSocialPeopleView: View {
    let title: LocalizedStringResource
    let nsid: String
    let parameters: [String: String]
    let collectionKey: String
    var actorKey: String? = nil

    @Environment(AppServices.self) private var services
    @Environment(\.routeNavigator) private var navigator
    @State private var people: [ExploreModel.Actor] = []
    @State private var cursor: String?
    @State private var consumedCursors: Set<String> = []
    @State private var isLoading = false
    @State private var hasLoaded = false
    @State private var errorMessage: String?

    var body: some View {
        List {
            ForEach(people) { person in
                Button {
                    guard let actor = try? ActorIdentifier(person.did) else { return }
                    navigator?(.profile(actor))
                } label: {
                    HStack(spacing: 12) {
                        TimelineAvatarView(avatarURL: person.avatar, actor: person.did)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(person.displayName ?? person.handle).font(.headline)
                            Text(verbatim: "@\(person.handle)")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        .lineLimit(1)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                    }
                    .foregroundStyle(.primary)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
            if isLoading {
                ProgressView().frame(maxWidth: .infinity)
            } else if let errorMessage {
                VStack(spacing: 8) {
                    Text(errorMessage).foregroundStyle(.secondary)
                    Button("Try Again") { Task { await load(reset: people.isEmpty) } }
                }
                .frame(maxWidth: .infinity)
            } else if cursor != nil {
                Color.clear.frame(height: 1).task(id: cursor) { await load(reset: false) }
            }
        }
        .listStyle(.plain)
        .overlay {
            if hasLoaded && people.isEmpty && !isLoading && errorMessage == nil {
                ContentUnavailableView("No People Yet", systemImage: "person.2")
            }
        }
        .roundedNavigationTitle(title)
        .task { if !hasLoaded { await load(reset: true) } }
        .refreshable { await load(reset: true) }
    }

    private func load(reset: Bool) async {
        guard !isLoading else { return }
        let requestedCursor = reset ? nil : cursor
        guard reset || requestedCursor != nil else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            var query = parameters
            query["limit"] = "100"
            query["cursor"] = requestedCursor
            let data = try await services.appViewRequest(nsid, query)
            try Task.checkCancellation()
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let rows = object[collectionKey] as? [[String: Any]] else {
                throw URLError(.cannotParseResponse)
            }
            let actorRows = actorKey.map { key in rows.compactMap { $0[key] as? [String: Any] } } ?? rows
            let decoded = try JSONDecoder().decode(
                [ExploreModel.Actor].self, from: JSONSerialization.data(withJSONObject: actorRows)
            )
            if reset { people = []; consumedCursors = [] }
            var known = Set(people.map(\.did))
            people.append(contentsOf: decoded.filter { known.insert($0.did).inserted })
            if let requestedCursor { consumedCursors.insert(requestedCursor) }
            let next = object["cursor"] as? String
            cursor = next.flatMap { $0.isEmpty || consumedCursors.contains($0) ? nil : $0 }
            hasLoaded = true
        } catch is CancellationError {
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
#endif
