import Foundation
import HTTPTypes
import Hummingbird
import NIOCore

/// Public routes for OAuth client metadata (no auth). Lets local / tunnel dev serve `client_id`
/// without deploying the Next.js `public/` files.
struct OAuthMetadataRoutes {
  let oauthPublicOrigin: String?

  func register(on router: Router<AppRequestContext>) {
    router.get("/oauth/client-metadata.json") { request, _ in
      try Self.response(
        oauthPublicOrigin: oauthPublicOrigin,
        request: request,
        encode: WebOAuthClientMetadata.buildJSON(publicOrigin:)
      )
    }
    router.get("/ios-client-metadata.json") { request, _ in
      try Self.response(
        oauthPublicOrigin: oauthPublicOrigin,
        request: request,
        encode: IosOAuthClientMetadata.buildJSON(publicOrigin:)
      )
    }
  }

  private static func response(
    oauthPublicOrigin: String?,
    request: Request,
    encode: (String) throws -> Data
  ) throws -> Response {
    guard
      let origin = OAuthPublicOrigin.resolve(
        request: request,
        configuredOrigin: oauthPublicOrigin
      )
    else {
      throw HTTPError(
        .internalServerError,
        message: "Cannot build OAuth metadata origin. Set OAUTH_PUBLIC_ORIGIN or use a Host header."
      )
    }

    let data: Data
    do {
      data = try encode(origin)
    } catch {
      throw HTTPError(.internalServerError, message: "Invalid OAUTH_PUBLIC_ORIGIN or Host for OAuth metadata.")
    }

    var headers: HTTPFields = [.contentType: "application/json; charset=utf-8"]
    if let acao = HTTPField.Name("Access-Control-Allow-Origin") {
      headers[acao] = "*"
    }
    return Response(
      status: .ok,
      headers: headers,
      body: .init(byteBuffer: ByteBuffer(data: data))
    )
  }
}
