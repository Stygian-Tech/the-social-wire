import SwiftUI

struct AddPublicationView: View {
    @Environment(SocialWireAppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss

    @State private var input: String
    @State private var title = ""
    @State private var result: ResolveAddPublicationResultDTO?
    @State private var isResolving = false
    @State private var isAdding = false
    @State private var errorMessage: String?

    init(initialInput: String = "") {
        _input = State(initialValue: initialInput)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Publication Address") {
                    TextField("URL, handle, DID, or AT-URI", text: $input)
                        .platformUncapitalizedTextInput()
                        .onSubmit { resolve() }
                        .onChange(of: input) { _, _ in
                            result = nil
                            errorMessage = nil
                        }

                    Button("Preview Publication", systemImage: "magnifyingglass", action: resolve)
                        .disabled(normalizedInput.isEmpty || isResolving)

                    if isResolving {
                        ProgressView("Resolving Publication")
                    }
                }

                if let result {
                    Section("Preview") {
                        PublicationResolutionPreviewView(
                            result: result,
                            isSubscribed: appModel.isSubscribed(to: result),
                            isAdding: isAdding,
                            showsAddButton: false,
                            onAdd: add
                        )

                        if result.kind == "rss" {
                            TextField("Custom Title", text: $title)
                        }
                    }
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Add Publication")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add", action: add)
                        .disabled(result == nil || isAdding || result.map(appModel.isSubscribed(to:)) == true)
                }
            }
            .task {
                guard !normalizedInput.isEmpty else { return }
                resolve()
            }
        }
    }

    private var normalizedInput: String {
        input.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func resolve() {
        guard !normalizedInput.isEmpty else { return }
        Task {
            isResolving = true
            errorMessage = nil
            defer { isResolving = false }
            do {
                result = try await appModel.resolvePublication(input: normalizedInput)
            } catch {
                result = nil
                errorMessage = error.localizedDescription
            }
        }
    }

    private func add() {
        guard let result else { return }
        Task {
            isAdding = true
            errorMessage = nil
            defer { isAdding = false }
            do {
                try await appModel.addResolvedPublication(
                    result,
                    title: title.isEmpty ? nil : title
                )
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
