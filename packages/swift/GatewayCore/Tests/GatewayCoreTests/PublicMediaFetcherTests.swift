import AsyncHTTPClient
import Foundation
import Hummingbird
import HummingbirdTesting
import NIOCore
import Testing
@testable import GatewayCore

@Suite("Source media SSRF guards")
struct PublicMediaFetcherTests {
  @Test("podcast tracker chains can opt into seven redirects while the default remains bounded")
  func trackerRedirectBudget() async throws {
    let fetch: (String) async throws -> PublicMediaFetcher.FetchHop = { url in
      let hop = Int(URL(string: url)!.lastPathComponent)!
      return hop < 7 ? .redirect("https://publisher.example/\(hop + 1)") : .body(Data("ID3".utf8))
    }
    let body = try await PublicMediaFetcher.fetchFollowingRedirects(url: "https://publisher.example/0",
      maximumRedirects: 10, deadline: .now.advanced(by: .seconds(1)), fetch: fetch)
    #expect(body == Data("ID3".utf8))
    await #expect(throws: PDSAccessTokenAttestationError.unavailable) {
      try await PublicMediaFetcher.fetchFollowingRedirects(url: "https://publisher.example/0",
        maximumRedirects: 5, deadline: .now.advanced(by: .seconds(1)), fetch: fetch)
    }
  }

  @Test("extended redirects still reject unsafe targets before transport", arguments: [
    "http://publisher.example/audio", "https://user:password@publisher.example/audio",
    "https://127.0.0.1/audio"
  ])
  func unsafeRedirectTargets(target: String) async throws {
    await #expect(throws: PDSAccessTokenAttestationError.invalid) {
      try await PublicMediaFetcher.fetchFollowingRedirects(url: "https://publisher.example/start",
        maximumRedirects: 10, deadline: .now.advanced(by: .seconds(1)),
        validateURL: { URL(string: $0)?.host != "127.0.0.1" }) { current in
          #expect(current == "https://publisher.example/start")
          return .redirect(target)
        }
    }
  }

  @Test("redirect budget rejects unbounded values and loops")
  func invalidRedirectBudget() async throws {
    await #expect(throws: PDSAccessTokenAttestationError.invalid) {
      try await PublicMediaFetcher.fetchFollowingRedirects(url: "https://publisher.example/start",
        maximumRedirects: 11, deadline: .now.advanced(by: .seconds(1))) { _ in
          Issue.record("Invalid budget must reject before transport")
          return .body(Data())
        }
    }
    await #expect(throws: PDSAccessTokenAttestationError.unavailable) {
      try await PublicMediaFetcher.fetchFollowingRedirects(url: "https://publisher.example/start",
        maximumRedirects: 10, deadline: .now.advanced(by: .seconds(1))) { _ in .redirect("/start") }
    }
  }
  @Test("metadata deadlines include a stalled response body after headers")
  func metadataBodyDeadline() async throws {
    let upstream = Router()
    upstream.get("/chapters") { _, _ -> Response in
      Response(status: .ok, body: ResponseBody { writer in
        try await writer.write(ByteBuffer(string: "{\"chapters\":"))
        try await Task.sleep(for: .milliseconds(500))
        try await writer.write(ByteBuffer(string: "[]}"))
        try await writer.finish(nil)
      })
    }
    let client = HTTPClient(eventLoopGroupProvider: .singleton)
    do {
      try await Application(router: upstream).test(.live) { server in
        let port = try #require(server.port)
        let response = try await client.execute(HTTPClientRequest(url: "http://localhost:\(port)/chapters"), timeout: .seconds(2))
        let started = ContinuousClock.now
        await #expect(throws: PDSAccessTokenAttestationError.unavailable) {
          _ = try await PublicMediaFetcher.collectBeforeDeadline(response, maximumBytes: 1024,
            deadline: .now.advanced(by: .milliseconds(100)))
        }
        #expect(started.duration(to: .now) < .milliseconds(400))
      }
    } catch { try? await client.shutdown(); throw error }
    try await client.shutdown()
  }
  @Test("JSON provider responses reject HTML and bound response bytes", arguments: ["application/json; charset=utf-8", "text/html"])
  func providerContentType(mime: String) async throws {
    let upstream = Router()
    upstream.get("/directory") { _, _ -> Response in
      Response(status: .ok, headers: [.contentType: mime], body: .init(byteBuffer: ByteBuffer(string: "{\"results\":[]}")))
    }
    let client = HTTPClient(eventLoopGroupProvider: .singleton)
    do {
      try await Application(router: upstream).test(.live) { server in
        let port = try #require(server.port)
        let response = try await client.execute(HTTPClientRequest(url: "http://localhost:\(port)/directory"), timeout: .seconds(2))
        if mime.hasPrefix("application/json") {
          let body = try await PublicMediaFetcher.collectBeforeDeadline(response, maximumBytes: 1024,
            deadline: .now.advanced(by: .seconds(1)), requiredContentType: "application/json")
          #expect(String(decoding: body, as: UTF8.self) == "{\"results\":[]}")
          let oversized = try await client.execute(HTTPClientRequest(url: "http://localhost:\(port)/directory"), timeout: .seconds(2))
          await #expect(throws: (any Error).self) {
            try await PublicMediaFetcher.collectBeforeDeadline(oversized, maximumBytes: 1,
              deadline: .now.advanced(by: .seconds(1)), requiredContentType: "application/json")
          }
        } else {
          await #expect(throws: PDSAccessTokenAttestationError.unavailable) {
            try await PublicMediaFetcher.collectBeforeDeadline(response, maximumBytes: 1024,
              deadline: .now.advanced(by: .seconds(1)), requiredContentType: "application/json")
          }
        }
      }
    } catch { try? await client.shutdown(); throw error }
    try await client.shutdown()
  }
  @Test("feed policy rejects before DNS or networking")
  func feedPolicy() async throws {
    let client = HTTPClient(eventLoopGroupProvider: .singleton)
    defer { Task { try? await client.shutdown() } }
    await #expect(throws: PDSAccessTokenAttestationError.invalid) {
      _ = try await PublicMediaFetcher.fetch(url: "https://unresolvable.invalid/?token=private", httpClient: client,
        maximumBytes: 100, validateURL: { _ in false })
    }
  }
  @Test("source fetch and stream reject insecure, credentialed, and private addresses",
    arguments: ["http://127.0.0.1/private", "https://user:password@example.com/private", "https://127.0.0.1/private"])
  func rejectedSources(url: String) async throws {
    let client = HTTPClient(eventLoopGroupProvider: .singleton)
    defer { Task { try? await client.shutdown() } }
    await #expect(throws: PDSAccessTokenAttestationError.invalid) {
      _ = try await PublicMediaFetcher.fetch(url: url, httpClient: client, maximumBytes: 100)
    }
    await #expect(throws: PDSAccessTokenAttestationError.invalid) {
      _ = try await PublicMediaFetcher.stream(url: url, httpClient: client, range: "bytes=0-100")
    }
  }
}
