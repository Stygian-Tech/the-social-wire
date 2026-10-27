#if os(iOS)
import Foundation
import Observation

@MainActor
@Observable
final class ViewerAltTextModel {
    private(set) var generatedText: String?
    private(set) var errorMessage: String?
    private(set) var isGenerating = false

    private var selectedImageID: URL?
    private var generation = UUID()
    private let generate: @MainActor (URL) async throws -> String

    init(generate: @escaping @MainActor (URL) async throws -> String = {
        try await FoundationModelService().altText(for: $0)
    }) {
        self.generate = generate
    }

    func select(_ imageID: URL) {
        guard selectedImageID != imageID else { return }
        selectedImageID = imageID
        generation = UUID()
        generatedText = nil
        errorMessage = nil
        isGenerating = false
    }

    func generateIfNeeded(for imageID: URL) async {
        select(imageID)
        guard generatedText == nil, errorMessage == nil, !isGenerating else { return }
        let requestGeneration = generation
        isGenerating = true
        defer {
            if generation == requestGeneration { isGenerating = false }
        }
        do {
            let text = try await generate(imageID)
            guard !Task.isCancelled, generation == requestGeneration else { return }
            generatedText = text
        } catch {
            guard !Task.isCancelled, generation == requestGeneration else { return }
            errorMessage = error.localizedDescription
        }
    }
}

#endif
