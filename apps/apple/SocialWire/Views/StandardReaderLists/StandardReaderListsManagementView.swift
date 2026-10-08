import SwiftUI

struct StandardReaderListsManagementView: View {
    let model: StandardReaderListsModel
    let publications: [StandardReaderListPublication]
    @Environment(\.dismiss) private var dismiss
    @State private var input = ""
    @State private var results: [StandardReaderList] = []
    @State private var name = ""
    @State private var description = ""
    @State private var selectedPublications = Set<String>()
    @State private var authors = ""
    @State private var error: String?
    @State private var searching = false
    @State private var searchEpoch = 0
    @State private var pendingDelete: StandardReaderList?
    @State private var pendingRemove: StandardReaderList?
    @State private var feedback = 0

    var body: some View {
        NavigationStack {
            Form {
                Section("Find Lists") {
                    TextField("Creator Handle, DID, or List Link", text: $input)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("lists.searchInput")
                    Button("Search Lists") { Task { await search() } }
                        .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || searching)
                        .accessibilityIdentifier("lists.search")
                    if searching { ProgressView() }
                    ForEach(results) { list in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(list.name)
                                if let description = list.description { Text(description).font(.caption).foregroundStyle(.secondary) }
                            }
                            Spacer()
                            Button("Save") { Task { await save(list) } }
                                .disabled(model.isSaving || model.lists.contains(where: { $0.uri == list.uri && $0.saved }))
                        }
                    }
                }
                Section("Create List") {
                    TextField("Name", text: $name).accessibilityIdentifier("lists.createName")
                    TextField("Description", text: $description, axis: .vertical)
                    ForEach(publications, id: \.publicationId) { publication in
                        Toggle(publication.title, isOn: Binding(
                            get: { selectedPublications.contains(publication.publicationId) },
                            set: { if $0 { selectedPublications.insert(publication.publicationId) } else { selectedPublications.remove(publication.publicationId) } }))
                    }
                    TextField("Author Handles or DIDs (Comma Separated)", text: $authors)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Create List") { Task { await create() } }
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isSaving)
                        .accessibilityIdentifier("lists.create")
                }
                Section("Your Lists") {
                    ForEach(model.lists) { list in
                        HStack {
                            Text(list.name)
                            Spacer()
                            if let url = StandardReaderListContract.shareURL(list.uri) {
                                ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }
                                    .accessibilityLabel("Share \(list.name)")
                            }
                            if list.saved {
                                Button("Remove") { pendingRemove = list }.disabled(model.isSaving)
                            }
                            if list.owned {
                                Button(role: .destructive) { pendingDelete = list } label: { Image(systemName: "trash") }
                                    .accessibilityLabel("Delete \(list.name)").disabled(model.isSaving)
                            }
                        }
                    }
                }
                if let error = error ?? model.error { Section { Text(error).foregroundStyle(.red) } }
            }
            .navigationTitle("Manage Lists")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .confirmationDialog("Delete List?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), presenting: pendingDelete) { list in
                Button("Delete List", role: .destructive) {
                    Task {
                        do { try await model.delete(list); feedback += 1 }
                        catch { self.error = error.localizedDescription }
                        pendingDelete = nil
                    }
                }
            } message: { list in Text("Delete \(list.name) from your PDS? This cannot be undone.") }
            .confirmationDialog("Remove Saved List?", isPresented: Binding(get: { pendingRemove != nil }, set: { if !$0 { pendingRemove = nil } }), presenting: pendingRemove) { list in
                Button("Remove List", role: .destructive) { Task { await save(list, remove: true) }; pendingRemove = nil }
                Button("Cancel", role: .cancel) { pendingRemove = nil }
            } message: { list in Text("Remove \(list.name) from your saved lists?") }
            .sensoryFeedback(.success, trigger: feedback)
        }
    }

    private func search() async {
        searchEpoch += 1
        let revision = searchEpoch
        searching = true; error = nil
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let values = value.hasPrefix("at://") || value.hasPrefix("https://")
                ? [try await model.resolve(value)] : try await model.searchCreator(value)
            guard revision == searchEpoch else { return }
            results = values
        } catch { if revision == searchEpoch { self.error = error.localizedDescription; results = [] } }
        if revision == searchEpoch { searching = false }
    }

    private func save(_ list: StandardReaderList, remove: Bool = false) async {
        error = nil
        do { try await model.save(list, remove: remove); feedback += 1 }
        catch { self.error = error.localizedDescription }
    }

    private func create() async {
        error = nil
        do {
            var userDIDs: [String] = []
            for author in authors.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }).filter({ !$0.isEmpty }) {
                userDIDs.append(try await model.resolveCreator(author))
            }
            _ = try await model.create(name: name, description: description,
                publications: publications.filter { selectedPublications.contains($0.publicationId) }.map(\.publicationId), users: Array(Set(userDIDs)).sorted())
            name = ""; description = ""; authors = ""; selectedPublications = []; feedback += 1
        } catch { self.error = error.localizedDescription }
    }
}
