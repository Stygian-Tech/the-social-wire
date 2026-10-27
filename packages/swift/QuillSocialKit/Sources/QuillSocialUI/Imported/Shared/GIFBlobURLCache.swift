#if os(iOS)
import Feeds
import Foundation

actor GIFBlobURLCache {
    static let shared = GIFBlobURLCache()
    private var urls: [String: URL] = [:]

    func url(did: String, cid: String) async throws -> URL {
        let key = did + "/" + cid
        if let cached = urls[key] { return cached }
        let url = try await ATProtoPublicRepository.blobURL(did: did, cid: cid)
        try Task.checkCancellation()
        if urls.count >= 128 { urls.removeAll(keepingCapacity: true) }
        urls[key] = url
        return url
    }
}

#endif
