#if os(iOS)
import Foundation
#if compiler(>=6.4) && canImport(FoundationModels)
import FoundationModels

@available(iOS 27, *)
private struct NativeFoundationModelService {
    enum ServiceError: LocalizedError {
        case unavailable(SystemLanguageModel.Availability.UnavailableReason)

        var errorDescription: String? {
            switch self {
            case .unavailable(.appleIntelligenceNotEnabled):
                "Apple Intelligence is not enabled."
            case .unavailable(.deviceNotEligible):
                "This device does not support Apple Intelligence."
            case .unavailable(.modelNotReady):
                "The on-device model is still downloading."
            @unknown default:
                "The on-device model is unavailable."
            }
        }
    }

    func translate(_ text: String, locale: Locale = .current) async throws -> String {
        let model = SystemLanguageModel.default
        guard case .available = model.availability else {
            if case let .unavailable(reason) = model.availability {
                throw ServiceError.unavailable(reason)
            }
            throw ServiceError.unavailable(.modelNotReady)
        }

        let language = locale.localizedString(forLanguageCode: locale.language.languageCode?.identifier ?? "en") ?? "English"
        let session = LanguageModelSession(
            model: model,
            instructions: """
            The person's locale is \(locale.identifier).
            You translate social media posts faithfully. Preserve names, links, emoji, tone, and line breaks.
            Respond only with the translation in \(language).
            """
        )
        return try await session.respond(to: text).content
    }

    func altText(for imageURL: URL) async throws -> String {
        let model = SystemLanguageModel.default
        guard case .available = model.availability else {
            if case let .unavailable(reason) = model.availability {
                throw ServiceError.unavailable(reason)
            }
            throw ServiceError.unavailable(.modelNotReady)
        }

        let (data, response) = try await URLSession.shared.data(from: imageURL)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw URLError(.badServerResponse)
        }

        return try await altText(
            for: data,
            fileExtension: imageURL.pathExtension.isEmpty ? "jpg" : imageURL.pathExtension
        )
    }

    func altText(for imageData: Data, mimeType: String) async throws -> String {
        let fileExtension: String
        switch mimeType {
        case "image/png": fileExtension = "png"
        case "image/gif": fileExtension = "gif"
        case "image/heic", "image/heif": fileExtension = "heic"
        default: fileExtension = "jpg"
        }
        return try await altText(for: imageData, fileExtension: fileExtension)
    }

    private func altText(for data: Data, fileExtension: String) async throws -> String {
        let model = SystemLanguageModel.default
        guard case .available = model.availability else {
            if case let .unavailable(reason) = model.availability {
                throw ServiceError.unavailable(reason)
            }
            throw ServiceError.unavailable(.modelNotReady)
        }

        let fileURL = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString)
            .appendingPathExtension(fileExtension)
        try data.write(to: fileURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let session = LanguageModelSession(
            model: model,
            instructions: "Write concise, objective accessibility alt text. Do not invent details or start with 'image of'."
        )
        return try await session.respond {
            "Describe this social media image for a screen reader in one or two sentences."
            Attachment(imageURL: fileURL)
        }.content
    }
}
#endif

struct FoundationModelService {
    private struct Unavailable: LocalizedError {
        var errorDescription: String? {
            "This feature requires a newer version of iOS and Apple Intelligence."
        }
    }

    func translate(_ text: String, locale: Locale = .current) async throws -> String {
#if compiler(>=6.4) && canImport(FoundationModels)
        guard #available(iOS 27, *) else { throw Unavailable() }
        return try await NativeFoundationModelService().translate(text, locale: locale)
#else
        throw Unavailable()
#endif
    }

    func altText(for imageURL: URL) async throws -> String {
#if compiler(>=6.4) && canImport(FoundationModels)
        guard #available(iOS 27, *) else { throw Unavailable() }
        return try await NativeFoundationModelService().altText(for: imageURL)
#else
        throw Unavailable()
#endif
    }

    func altText(for imageData: Data, mimeType: String) async throws -> String {
#if compiler(>=6.4) && canImport(FoundationModels)
        guard #available(iOS 27, *) else { throw Unavailable() }
        return try await NativeFoundationModelService().altText(for: imageData, mimeType: mimeType)
#else
        throw Unavailable()
#endif
    }
}

#endif
