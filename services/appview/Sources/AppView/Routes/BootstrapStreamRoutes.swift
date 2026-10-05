import Foundation
import GatewayCore
import Hummingbird
import Logging

struct BootstrapStreamRoutes {
  let bootstrapStreamService: BootstrapStreamService

  func register(on group: RouterGroup<GatewayRequestContext>) {
    group.get("/v1/appview/bootstrap-stream") { request, context async throws -> Response in
      guard let auth = context.authContext else { throw HTTPError(.unauthorized) }
      let includeLists = request.uri.queryParameters.get("includeLists") == "true"
      var headers = HTTPFields()
      headers[.contentType] = "application/x-ndjson"
      headers[.cacheControl] = "no-cache"
      return Response(
        status: .ok,
        headers: headers,
        body: ResponseBody { writer in
          try await bootstrapStreamService.writeStream(auth: auth, writer: &writer, includeLists: includeLists)
        }
      )
    }
  }
}
