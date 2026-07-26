import Hummingbird
import Testing

@testable import GatewayCore

@Suite("Request trace telemetry")
struct RequestTraceMiddlewareTests {
  @Test("expected HTTP errors retain their real status")
  func httpErrorStatus() {
    #expect(RequestTraceMiddleware.statusCode(for: HTTPError(.badRequest)) == 400)
    #expect(RequestTraceMiddleware.statusCode(for: HTTPError(.conflict)) == 409)
    #expect(RequestTraceMiddleware.statusCode(for: HTTPError(.tooManyRequests)) == 429)
    #expect(RequestTraceMiddleware.statusCode(for: ExampleHTTPFailure()) == 422)
    #expect(RequestTraceMiddleware.statusCode(for: ExampleFailure()) == 500)
  }

  @Test("dynamic routes use bounded templates")
  func routeTemplates() {
    #expect(
      RequestTraceMiddleware.routeTemplate("/v1/operations/gaps/gap-123/investigation")
        == "/v1/operations/gaps/:id/investigation"
    )
    #expect(
      RequestTraceMiddleware.routeTemplate("/v1/publications/folders/3kexample")
        == "/v1/publications/folders/:rkey"
    )
    #expect(
      RequestTraceMiddleware.routeTemplate("/v1/publications/subscriptions/3kexample")
        == "/v1/publications/subscriptions/:rkey"
    )
    #expect(
      RequestTraceMiddleware.routeTemplate("/v1/publications/rss-subscriptions/3kexample")
        == "/v1/publications/rss-subscriptions/:rkey"
    )
    #expect(
      RequestTraceMiddleware.routeTemplate("/v1/latr/saves/3kexample/state")
        == "/v1/latr/saves/:rkey/state"
    )
    #expect(
      RequestTraceMiddleware.routeTemplate("/v1/appview/bootstrap-stream")
        == "/v1/appview/bootstrap-stream"
    )
    #expect(
      RequestTraceMiddleware.routeTemplate("/custom/did:plc:abcdefghijklmnopqrstuvwxyz0123456789")
        == "/custom/:id"
    )
  }
}

private struct ExampleFailure: Error {}

private struct ExampleHTTPFailure: HTTPResponseError {
  let status: HTTPResponse.Status = .unprocessableContent

  func response(
    from request: Request,
    context: some RequestContext
  ) throws -> Response {
    Response(status: status)
  }
}
