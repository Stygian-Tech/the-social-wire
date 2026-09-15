import Foundation
import GatewayCore
import Hummingbird
import HummingbirdTesting
import Testing
import ThinAppViewCore
@testable import AppView

@Suite("AppView feed timing evidence")
struct AppViewFeedTimingEvidenceTests {
  @Test("retries share one diagnostic record containing only fixed numeric stages")
  func failedRetries() async throws {
    let capture = AppViewFeedLogCapture()
    let router = Router(context: GatewayRequestContext.self)
    router.add(middleware: AppViewFeedErrorMiddleware())
    router.get("/v1/appview/entries") { _, context -> Response in
      try await AppViewFeedExecution.run(requestId: context.requestId) {
        try await AppViewFeedRequestTimings.measure(.publicationSelect) {
          throw HTTPError(.serviceUnavailable, message: "private SQL did:plc:viewer https://secret.example")
        }
      }
    }
    try await Application(router: router, logger: capture.logger()).test(.router) { client in
      let response = try await client.execute(uri: "/v1/appview/entries?did=did:plc:viewer", method: .get)
      #expect(response.status == .serviceUnavailable)
      let records = capture.records.filter { $0["publication_select_count"] != nil }
      #expect(records.count == 1)
      let record = try #require(records.first)
      #expect(record["publication_select_count"]?.description == "2")
      #expect(record["pg_query_count"]?.description == "0")
      #expect(!record.description.contains("did:plc:viewer"))
      #expect(!record.description.contains("private SQL"))
      #expect(!record.description.contains("secret.example"))
    }
  }

  @Test("fast successful requests emit no timing log")
  func fastSuccess() async throws {
    let capture = AppViewFeedLogCapture()
    let router = Router(context: GatewayRequestContext.self)
    router.add(middleware: AppViewFeedErrorMiddleware())
    router.get("/v1/appview/feed") { _, _ -> Response in
      await AppViewFeedRequestTimings.measure(.cacheLookup) { Response(status: .ok) }
    }
    try await Application(router: router, logger: capture.logger()).test(.router) { client in
      let response = try await client.execute(uri: "/v1/appview/feed", method: .get)
      #expect(response.status == .ok)
      #expect(capture.records.allSatisfy { $0["cache_lookup_count"] == nil })
    }
  }

  @Test("slow successful requests emit one stage summary")
  func slowSuccess() async throws {
    let capture = AppViewFeedLogCapture()
    let router = Router(context: GatewayRequestContext.self)
    router.add(middleware: AppViewFeedErrorMiddleware())
    router.get("/v1/appview/feed") { _, _ -> Response in
      try await AppViewFeedRequestTimings.measure(.cacheLookup) {
        try await Task.sleep(for: .milliseconds(550))
        return Response(status: .ok)
      }
    }
    try await Application(router: router, logger: capture.logger()).test(.router) { client in
      let response = try await client.execute(uri: "/v1/appview/feed", method: .get)
      #expect(response.status == .ok)
      let records = capture.records.filter { $0["cache_lookup_count"] != nil }
      #expect(records.count == 1)
      let record = try #require(records.first)
      #expect(record["cache_lookup_count"]?.description == "1")
      #expect(record["status"]?.description == "200")
      #expect((Int(record["cache_lookup_ms"]?.description ?? "") ?? 0) >= 500)
    }
  }
}
