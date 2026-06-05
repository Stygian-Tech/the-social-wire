import Foundation

enum SavedLinkEmbedURL {
    static func isPocketReaderHostname(_ hostname: String) -> Bool {
        let h = hostname.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return h == "getpocket.com"
            || h.hasSuffix(".getpocket.com")
            || h == "readitlaterlist.com"
            || h.hasSuffix(".pocket.com")
            || h == "pckt.it"
            || h == "pkt.cool"
    }

    static func isPoorIframeEmbedTarget(_ rawURL: String) -> Bool {
        guard let url = URL(string: rawURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = url.host
        else { return false }
        return isPocketReaderHostname(host)
    }

    static func resolveEmbedURL(for save: MergedLatrSave) -> String? {
        let linked = save.linkedWebUrl?.trimmingCharacters(in: .whitespacesAndNewlines)
        let primary: String? = {
            switch save {
            case .external(let row):
                return row.url.trimmingCharacters(in: .whitespacesAndNewlines)
            case .native(let row):
                return row.url?.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }()

        if let primary, !primary.isEmpty, isPoorIframeEmbedTarget(primary) {
            if let linked, !linked.isEmpty { return linked }
            return primary
        }
        if let primary, !primary.isEmpty { return primary }
        if let linked, !linked.isEmpty { return linked }
        return nil
    }

    static func previewURL(for save: MergedLatrSave) -> URL? {
        guard let raw = resolveEmbedURL(for: save) else { return nil }
        let normalized = PublicURLNormalizer.normalizeHttpURLToHTTPS(raw)
        return URL(string: normalized)
    }
}
