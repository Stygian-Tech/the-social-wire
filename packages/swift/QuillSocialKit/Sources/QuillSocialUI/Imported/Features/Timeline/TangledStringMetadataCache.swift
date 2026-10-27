#if os(iOS)
import Feeds
import Foundation

actor TangledStringMetadataCache {
    private var values: [URL: TangledStringEmbedMetadata] = [:]
    private var tasks: [URL: Task<TangledStringEmbedMetadata?, Never>] = [:]

    func metadata(for url: URL) async -> TangledStringEmbedMetadata? {
        if let value = values[url] { return value }
        if let task = tasks[url] { return await task.value }

        let task = Task { await Self.load(url) }
        tasks[url] = task
        let value = await task.value
        tasks[url] = nil
        if let value { values[url] = value }
        return value
    }

    private static func load(_ url: URL) async -> TangledStringEmbedMetadata? {
        let components = url.pathComponents
        guard components.count >= 4,
              components[1] == "strings",
              let actor = components[2].removingPercentEncoding else { return nil }
        let rkey = components[3]
        guard let did = try? await ATProtoPublicRepository.resolveDID(for: actor),
              let data = try? await ATProtoPublicRepository.record(
                uri: "at://\(did)/sh.tangled.string/\(rkey)"
              ),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = object["value"] as? [String: Any],
              let contents = value["contents"] as? String,
              !contents.isEmpty else { return nil }

        let profile = await profile(for: did)
        return TangledStringEmbedMetadata(
            contents: contents,
            filename: value["filename"] as? String ?? "Snippet",
            description: value["description"] as? String,
            authorName: profile?.name,
            authorAvatarURL: profile?.avatar
        )
    }

    private static func profile(for did: String) async -> (name: String, avatar: URL?)? {
        var components = URLComponents(string: "https://public.api.bsky.app/xrpc/app.bsky.actor.getProfile")!
        components.queryItems = [URLQueryItem(name: "actor", value: did)]
        guard let url = components.url,
              let (data, response) = try? await URLSession.shared.data(from: url),
              let http = response as? HTTPURLResponse,
              200..<300 ~= http.statusCode,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = object["displayName"] as? String ?? object["handle"] as? String else {
            return nil
        }
        return (name, (object["avatar"] as? String).flatMap(URL.init(string:)))
    }
}

#endif
