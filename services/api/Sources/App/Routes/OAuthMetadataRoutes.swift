import Foundation
import HTTPTypes
import Hummingbird
import NIOCore

/// Public routes for OAuth client metadata (no auth). Lets local / tunnel dev serve `client_id`
/// without deploying the Next.js `public/` files.
struct OAuthMetadataRoutes {
  let oauthPublicOrigin: String?
  /// Passed into **`OAuthPublicOrigin`** for **`/ios-client-metadata.json`** only (defaults **`nil`** → **`Host`**-derived).
  let oauthIosMetadataOrigin: String?

  func register(on router: Router<AppRequestContext>) {
    router.get("/oauth/client-metadata.json") { request, _ in
      try Self.webMetadataResponse(
        request: request,
        oauthRedirectOrigin: oauthPublicOrigin
      )
    }
    router.get("/ios-client-metadata.json") { request, _ in
      try Self.response(
        oauthConfiguredOrigin: oauthIosMetadataOrigin,
        request: request,
        encode: IosOAuthClientMetadata.buildJSON(publicOrigin:)
      )
    }
  }

  private static func webMetadataResponse(
    request: Request,
    oauthRedirectOrigin: String?
  ) throws -> Response {
    guard
      let metadataOrigin = OAuthPublicOrigin.resolve(
        request: request,
        configuredOrigin: nil
      )
    else {
      throw HTTPError(
        .internalServerError,
        message:
          "Cannot resolve public origin for OAuth metadata. Ensure Host (and X-Forwarded-Proto behind a proxy) is set."
      )
    }

    let redirectOrigin: String = {
      guard let raw = oauthRedirectOrigin?.trimmingCharacters(in: .whitespacesAndNewlines),
            !raw.isEmpty
      else { return metadataOrigin }
      return raw
    }()

    let data: Data
    do {
      data = try WebOAuthClientMetadata.buildJSON(
        publicOrigin: metadataOrigin,
        redirectOrigin: redirectOrigin
      )
    } catch {
      throw HTTPError(.internalServerError, message: "Invalid public origin for OAuth metadata JSON.")
    }

    return try jsonResponse(data: data)
  }

  private static func response(
    oauthConfiguredOrigin: String?,
    request: Request,
    encode: (String) throws -> Data
  ) throws -> Response {
    guard
      let origin = OAuthPublicOrigin.resolve(
        request: request,
        configuredOrigin: oauthConfiguredOrigin
      )
    else {
      throw HTTPError(
        .internalServerError,
        message:
          "Cannot resolve public origin for OAuth metadata. For /ios-client-metadata.json ensure Host (and X-Forwarded-Proto behind a proxy) or set OAUTH_IOS_METADATA_ORIGIN; for /oauth/client-metadata.json set OAUTH_PUBLIC_ORIGIN if needed."
      )
    }

    let data: Data
    do {
      data = try encode(origin)
    } catch {
      throw HTTPError(.internalServerError, message: "Invalid public origin for OAuth metadata JSON.")
    }

    return try jsonResponse(data: data)
  }

  private static func jsonResponse(data: Data) throws -> Response {
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
