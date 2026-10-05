import AsyncHTTPClient
import Foundation
import Hummingbird
import HummingbirdTesting
import NIOCore
import Testing
@testable import GatewayCore

@Suite("Source media SSRF guards")
struct PublicMediaFetcherTests {
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
