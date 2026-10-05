import Foundation
import GatewayCore
import Hummingbird
import ThinAppViewCore

struct PodcastImageRoutes {
  let service: PodcastService
  func register(on group: RouterGroup<GatewayRequestContext>) {
    group.get("/v1/podcasts/image") { request, context async throws -> Response in
      guard let auth = context.authContext else { throw HTTPError(.unauthorized) }
      let query = request.uri.queryParameters
      let kind = query.get("kind") ?? "artwork"
      let index = Int(query.get("index") ?? "0") ?? -1
      guard index >= 0, index < 1000 else { throw HTTPError(.badRequest) }
      var url: String?
      if let id = query.get("showId") {
        guard let show = PodcastPrivateCatalog.isPrivateID(id)
          ? try await service.store.privateShow(viewer: auth.did, id: id)
          : try await service.store.show(id: id) else { throw HTTPError(.notFound) }
        if kind == "artwork" { url = show.artworkUrl }
        if kind == "host", show.hosts.indices.contains(index) { url = show.hosts[index].imageUrl }
      } else if let id = query.get("episodeId"), let episode = try await service.episode(id: id, viewer: auth.did) {
        if kind == "artwork" { url = episode.artworkUrl }
        if kind == "showArtwork" { url = episode.showArtworkUrl }
        if kind == "chapter", episode.chapters.indices.contains(index) { url = episode.chapters[index].artworkUrl }
      }
      guard let url else { throw HTTPError(.notFound) }
      let data: Data
      do { data = try await PublicMediaFetcher.fetch(url: url, httpClient: service.http, maximumBytes: 5 * 1024 * 1024) }
      catch { throw HTTPError(.badGateway, message: "Podcast Image Could Not Be Loaded") }
      guard let type = PodcastImage.mimeType(data) else { throw HTTPError(.unsupportedMediaType) }
      return Response(status: .ok, headers: [.contentType: type, .cacheControl: "private, no-store", .init("X-Content-Type-Options")!: "nosniff"], body: .init(byteBuffer: .init(data: data)))
    }
  }
}
