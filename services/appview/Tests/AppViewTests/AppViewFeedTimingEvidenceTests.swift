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

  @Test("failure diagnostics allow only bounded feed query categories")
  func boundedQueryCategories() async throws {
    let capture = AppViewFeedLogCapture()
    let router = Router(context: GatewayRequestContext.self)
    router.add(middleware: AppViewFeedErrorMiddleware())
    router.get("/v1/appview/feed") { _, _ -> Response in
      throw HTTPError(.serviceUnavailable)
    }
    try await Application(router: router, logger: capture.logger()).test(.router) { client in
      let response = try await client.execute(
        uri: "/v1/appview/feed?kind=folder&filter=unread&limit=24&id=private-feed&cursor=private-cursor",
        method: .get
      )
      #expect(response.status == .serviceUnavailable)
      let record = try #require(capture.records.last { $0["feed_filter"] != nil })
      #expect(record["feed_kind"]?.description == "folder")
      #expect(record["feed_filter"]?.description == "unread")
      #expect(record["feed_limit"]?.description == "24")
      #expect(record["feed_has_cursor"]?.description == "true")
      #expect(!record.description.contains("private-feed"))
      #expect(!record.description.contains("private-cursor"))

      let invalid = try await client.execute(
        uri: "/v1/appview/feed?kind=private-kind&filter=private-filter&limit=1000000",
        method: .get
      )
      #expect(invalid.status == .serviceUnavailable)
      let invalidRecord = try #require(capture.records.last { $0["feed_has_cursor"] != nil })
      #expect(invalidRecord["feed_kind"] == nil)
      #expect(invalidRecord["feed_filter"] == nil)
      #expect(invalidRecord["feed_limit"] == nil)
      #expect(invalidRecord["feed_has_cursor"]?.description == "false")
      #expect(!invalidRecord.description.contains("private-kind"))
      #expect(!invalidRecord.description.contains("private-filter"))
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
