import SwiftUI

struct SocialListsView: View {
    @Bindable var model: SocialCatalogModel
    let navigate: (SocialRoute) -> Void
    @State private var editingList: SocialListSummary?
    @State private var showsEditor = false
    @State private var deletingList: SocialListSummary?
    var body: some View {
        List(model.lists) { list in
            Button { navigate(.list(uri: list.uri, name: list.name)) } label: {
                HStack { SocialAvatarView(url: list.avatar, name: list.name); VStack(alignment: .leading) { Text(list.name).font(.headline); Text(list.description).font(.caption).foregroundStyle(.secondary).lineLimit(2); Text("\(list.itemCount) Members").font(.caption2).foregroundStyle(.secondary) } }
            }.buttonStyle(.plain)
                .swipeActions {
                    Button("Edit", systemImage: "pencil") { editingList = list; showsEditor = true }
                    Button("Delete", systemImage: "trash", role: .destructive) { deletingList = list }
                }
        }
        .overlay { if model.isLoading && model.lists.isEmpty { ProgressView() } else if let error = model.error, model.lists.isEmpty { ContentUnavailableView("Lists Unavailable", systemImage: "list.bullet", description: Text(error)) } }
        .task { if model.lists.isEmpty { await model.loadLists() } }
        .toolbar { Button("New List", systemImage: "plus") { editingList = nil; showsEditor = true } }
        .sheet(isPresented: $showsEditor) { SocialListEditorView(list: editingList) { name, description, member in await model.saveList(editingList, name: name, description: description, memberDID: member) } }
        .confirmationDialog("Delete This List?", isPresented: Binding(get: { deletingList != nil }, set: { if !$0 { deletingList = nil } }), titleVisibility: .visible) {
            Button("Delete List", role: .destructive) { if let list = deletingList { Task { await model.deleteList(list) } }; deletingList = nil }
        }
    }
}

private struct SocialListEditorView: View {
    @Environment(\.dismiss) private var dismiss
    let list: SocialListSummary?
    let save: (String, String, String) async -> Bool
    @State private var name: String
    @State private var description: String
    @State private var memberDID = ""
    @State private var saving = false

    init(list: SocialListSummary?, save: @escaping (String, String, String) async -> Bool) {
        self.list = list; self.save = save
        _name = State(initialValue: list?.name ?? "")
        _description = State(initialValue: list?.description ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                TextField("Description", text: $description, axis: .vertical)
                if list != nil { TextField("Add Member DID", text: $memberDID).textInputAutocapitalization(.never).autocorrectionDisabled() }
            }
            .navigationTitle(list == nil ? "New List" : "Edit List")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { saving = true; Task { if await save(name, description, memberDID) { dismiss() }; saving = false } }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || saving) }
            }
        }
    }
}
