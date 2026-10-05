import AsyncHTTPClient
import Testing
@testable import GatewayCore

@Suite("Source media SSRF guards")
struct PublicMediaFetcherTests {
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
