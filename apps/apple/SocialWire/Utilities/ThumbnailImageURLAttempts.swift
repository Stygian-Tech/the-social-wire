import Foundation

enum ThumbnailImageURLAttempts {
    static func candidates(primary: String?, fallback: String?) -> [URL] {
        var normalized: [String] = []
        for raw in [primary, fallback] {
            guard let raw else { continue }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let value = PublicURLNormalizer.normalizeHttpURLToHTTPS(trimmed)
            if !normalized.contains(value) {
                normalized.append(value)
            }
        }

        let withoutBridgyBlob = normalized.filter { !PublicURLNormalizer.isBridgySyncGetBlobURL($0) }
        guard !withoutBridgyBlob.isEmpty else { return [] }
        return withoutBridgyBlob.compactMap { URL(string: $0) }
    }
}
