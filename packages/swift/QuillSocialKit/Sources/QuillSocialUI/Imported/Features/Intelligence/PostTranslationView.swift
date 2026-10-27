#if os(iOS)
import SwiftUI

struct PostTranslationView: View {
    let text: String

    @State private var translation: String?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                Section("Original") {
                    Text(text)
                }

                Section("Translation") {
                    if let translation {
                        Text(translation)
                            .textSelection(.enabled)
                    } else if let errorMessage {
                        ContentUnavailableView(
                            "Translation Unavailable",
                            systemImage: "translate",
                            description: Text(errorMessage)
                        )
                    } else {
                        ProgressView("Translating")
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            .roundedNavigationTitle("Translate Post")
            .navigationBarTitleDisplayMode(.inline)
        }
        .task {
            do {
                translation = try await FoundationModelService().translate(text)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

#endif
