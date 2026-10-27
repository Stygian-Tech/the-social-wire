#if os(iOS)
import SwiftUI

struct LabelerModerationView: View {
    let did: String

    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var model = LabelerModerationModel()
    @State private var saveError: String?

    var body: some View {
        List {
            if let profile = model.profile {
                Section {
                    HStack(spacing: 12) {
                        AsyncImage(url: profile.avatar) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            Image(systemName: "person.crop.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .frame(width: 48, height: 48)
                        .clipShape(.circle)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(profile.displayName ?? profile.handle)
                                .font(.headline)
                            Text("@\(profile.handle)")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section("Labels") {
                if model.isLoading {
                    ProgressView()
                } else if let errorMessage = model.errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.secondary)
                } else if model.labels.isEmpty {
                    Text("This labeler doesn’t publish configurable labels.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.labels) { label in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(label.name)
                            if let description = label.description {
                                Text(description)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Picker(
                                label.name,
                                selection: visibilityBinding(for: label)
                            ) {
                                Text("Show").tag("ignore")
                                Text("Warn").tag("warn")
                                Text("Hide").tag("hide")
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .roundedNavigationTitle("Labeler")
        .task { await model.load(did: did, services: services) }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    Task {
                        do {
                            try await model.save(did: did, services: services)
                            dismiss()
                        } catch {
                            saveError = "The Social Wire couldn’t save these moderation settings."
                        }
                    }
                }
                .disabled(model.isLoading || model.labels.isEmpty)
            }
        }
        .alert("Couldn’t Save", isPresented: errorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(saveError ?? "Please try again.")
        }
    }

    private func visibilityBinding(for label: LabelerModerationModel.LabelOption) -> Binding<String> {
        Binding(
            get: { model.visibility[label.id] ?? label.defaultVisibility },
            set: { model.visibility[label.id] = $0 }
        )
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } }
        )
    }
}

#endif
