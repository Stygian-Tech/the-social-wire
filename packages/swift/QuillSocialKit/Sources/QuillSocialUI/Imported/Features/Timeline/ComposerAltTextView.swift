#if os(iOS)
import SwiftUI

struct ComposerAltTextView: View {
    let attachment: PostComposerModel.Attachment
    let allowsGeneration: Bool
    let onSave: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var altText: String
    @State private var isGenerating = false
    @State private var errorMessage: String?
    @State private var generationCount = 0

    init(
        attachment: PostComposerModel.Attachment,
        allowsGeneration: Bool = true,
        onSave: @escaping (String) -> Void
    ) {
        self.attachment = attachment
        self.allowsGeneration = allowsGeneration
        self.onSave = onSave
        _altText = State(initialValue: attachment.altText)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    AnimatedImageView(data: attachment.data, contentMode: .fit)
                        .aspectRatio(
                            CGFloat(attachment.width) / CGFloat(attachment.height),
                            contentMode: .fit
                        )
                        .clipShape(.rect(cornerRadius: 12))
                        .accessibilityHidden(true)
                }

                Section {
                    TextEditor(text: $altText)
                        .frame(minHeight: 120)
                        .accessibilityLabel("Photo Description")

                    if allowsGeneration {
                        Button("Generate Alt Text", systemImage: "apple.intelligence") {
                            generateAltText()
                        }
                        .disabled(isGenerating)

                        if isGenerating {
                            ProgressView("Generating Alt Text")
                        }
                    }
                } header: {
                    Text("Alt Text")
                } footer: {
                    Text(allowsGeneration
                         ? "Describe the important visual details for people who can’t see the photo. Generated text stays on this device until you publish the post."
                         : "Describe the important visual details for people who can’t see the photo.")
                }
            }
            .navigationTitle("Photo Description")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(altText.trimmingCharacters(in: .whitespacesAndNewlines))
                        dismiss()
                    }
                }
            }
            .alert("Alt Text Unavailable", isPresented: errorBinding) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "Please try again.")
            }
            .sensoryFeedback(.success, trigger: generationCount)
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    private func generateAltText() {
        isGenerating = true
        errorMessage = nil
        Task {
            defer { isGenerating = false }
            do {
                altText = try await FoundationModelService().altText(
                    for: attachment.data,
                    mimeType: attachment.mimeType
                )
                generationCount += 1
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

#endif
