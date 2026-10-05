import AsyncHTTPClient
import Foundation
import GatewayCore
import HTTPTypes
import Hummingbird
import ThinAppViewCore

struct PodcastAssetRoutes {
  let service: PodcastService
  let workerURL: String
  let secret: String
  func registerMedia(on group: RouterGroup<GatewayRequestContext>) {
    group.get("/v1/podcasts/media") { request, context async throws -> Response in
      guard let auth = context.authContext, let id = request.uri.queryParameters.get("episodeId"),
        let episode = try await service.episode(id: id, viewer: auth.did)
      else { throw HTTPError(.notFound) }
      let result: (response: HTTPClientResponse, client: HTTPClient)
      do {
        result = try await PublicMediaFetcher.stream(
          url: episode.audioUrl, httpClient: service.http, range: request.headers[.range])
      } catch {
        throw HTTPError(.badGateway, message: "Podcast Media Could Not Be Loaded")
      }
      let reply = result.response
      var headers = HTTPFields()
      for name in ["Content-Type", "Content-Length", "Content-Range", "Accept-Ranges"] {
        if let field = HTTPField.Name(name), let value = reply.headers.first(name: name) {
          headers[field] = value
        }
      }
      headers[.cacheControl] = "private, no-store"
      return Response(
        status: HTTPResponse.Status(code: Int(reply.status.code)), headers: headers,
        body: ResponseBody { writer in
          do {
            for try await chunk in reply.body { try await writer.write(chunk) }
            try await result.client.shutdown()
            try await writer.finish(nil)
          } catch {
            try? await result.client.shutdown()
            if episode.visibility == "private" {
              throw HTTPError(.badGateway, message: "Private Podcast Media Could Not Be Loaded")
            }
            throw error
          }
        })
    }
  }
  func register(on group: RouterGroup<GatewayRequestContext>, router: Router<GatewayRequestContext>)
  {
    group.get("/v1/podcasts/assets") { request, context async throws -> Response in
      guard let auth = context.authContext, let id = request.uri.queryParameters.get("clipId"),
        let clip = try await service.store.clip(id: id, viewer: auth.did), clip.status == "complete"
      else { throw HTTPError(.notFound) }
      return try await proxy(request: request, clip: clip, publicAsset: false)
    }
    router.get("/v1/podcasts/public/assets") { request, _ async throws -> Response in
      guard let id = request.uri.queryParameters.get("clipId"),
        let clip = try await service.store.clip(id: id, viewer: nil, publishedOnly: true),
        let uri = clip.publishedUri,
        let record = try await service.repo.getRecordByAtUri(auth: nil, atUri: uri),
        PodcastRoutes.matches(record.values, clip: clip)
      else { throw HTTPError(.notFound) }
      return try await proxy(request: request, clip: clip, publicAsset: true)
    }
  }
  private func proxy(request: Request, clip: PodcastClip, publicAsset: Bool) async throws
    -> Response
  {
    guard let format = request.uri.queryParameters.get("format"),
      ["audio", "video"].contains(format), UUID(uuidString: clip.id) != nil
    else { throw HTTPError(.badRequest) }
    let filename = format == "audio" ? "audio.m4a" : "audiogram.mp4"
    let path = publicAsset ? "/assets/" : "/internal/assets/"
    var req = HTTPClientRequest(
      url: workerURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + path + clip.id + "/"
        + filename)
    req.headers.add(name: "X-Podcast-Media-Secret", value: secret)
    if let range = request.headers[.range] { req.headers.add(name: "Range", value: range) }
    let reply = try await service.http.execute(req, timeout: .seconds(30))
    let status = HTTPResponse.Status(code: Int(reply.status.code))
    var headers = HTTPFields()
    for name in ["Content-Type", "Content-Length", "Content-Range", "Accept-Ranges"] {
      if let field = HTTPField.Name(name), let value = reply.headers.first(name: name) {
        headers[field] = value
      }
    }
    headers[.cacheControl] = "private, no-store"
    return Response(
      status: status, headers: headers,
      body: ResponseBody { writer in
        for try await chunk in reply.body { try await writer.write(chunk) }
        try await writer.finish(nil)
      })
  }
}
