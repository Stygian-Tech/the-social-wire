import Foundation

/// Each options event replaces the prior snapshot; counts are final only after done.
enum FeedReadAgeStreamEvent: Decodable, Sendable {
    case options(FeedReadAgeResponse)
    case done
    case error(String)

    private enum CodingKeys: String, CodingKey {
        case type, message
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "options": self = .options(try FeedReadAgeResponse(from: decoder))
        case "done": self = .done
        case "error": self = .error(try container.decode(String.self, forKey: .message))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: container, debugDescription: "Unknown read-age stream event."
            )
        }
    }

    @MainActor
    static func consume<Lines: AsyncSequence>(
        _ lines: Lines,
        onOptions: @escaping @MainActor ([FeedReadAgeOption]) -> Void
    ) async throws -> FeedReadAgeResponse where Lines.Element == String {
        var latest: FeedReadAgeResponse?
        for try await line in lines {
            try Task.checkCancellation()
            guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            switch try JSONDecoder().decode(Self.self, from: Data(line.utf8)) {
            case .options(let result):
                latest = result
                onOptions(result.options)
            case .done:
                guard let latest else {
                    throw SocialWireError.badResponse("Read options ended without a result.")
                }
                return latest
            case .error(let message):
                throw SocialWireError.badResponse(message)
            }
        }
        throw SocialWireError.badResponse("Read options were interrupted. Please try again.")
    }

}
