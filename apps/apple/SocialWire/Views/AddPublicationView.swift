import SwiftUI

struct AddPublicationView: View {
    @Environment(SocialWireAppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    @State private var input = ""
    @State private var title = ""
    @State private var isAdding = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("URL, handle, DID, or AT-URI", text: $input)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Custom Title", text: $title)
                } footer: {
                    Text("The app first treats web URLs as RSS/Atom feed subscriptions and handles or DIDs as standard.site publication subscriptions.")
                }
            }
            .navigationTitle("Add Publication")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task {
                            isAdding = true
                            await appModel.addPublication(input: input, title: title.isEmpty ? nil : title)
                            isAdding = false
                            dismiss()
                        }
                    } label: {
                        if isAdding { ProgressView() } else { Text("Add") }
                    }
                    .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isAdding)
                }
            }
        }
    }
}
