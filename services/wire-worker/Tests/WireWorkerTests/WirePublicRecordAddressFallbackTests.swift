import AsyncHTTPClient
import Foundation
import NIOCore
import NIOSSL
import Testing

@testable import WireWorkerCore

@Suite("Bounded public record address fallback")
struct WirePublicRecordAddressFallbackTests {
  @Test("validated addresses are deduplicated with IPv4 preferred and at most two candidates")
  func addressPreference() throws {
    #expect(try WirePublicRecordAddressFallback.candidates([
      "2606:4700:4700::1111", "8.8.8.8", "1.1.1.1", "1.1.1.1", "9.9.9.9",
    ]) == ["1.1.1.1", "8.8.8.8"])
    #expect(try WirePublicRecordAddressFallback.candidates([
      "2606:4700:4700::1111", "1.1.1.1",
    ]) == ["1.1.1.1", "2606:4700:4700::1111"])
  }

  @Test("every DNS answer is checked before even the first safe address is used")
  func rejectsUnsafeTailAddress() async {
    let attempts = Attempts()
    await #expect(throws: WirePublicRecordQueryError.unsafeEndpoint) {
      try await WirePublicRecordAddressFallback.run(addresses: ["1.1.1.1", "8.8.8.8", "127.0.0.1"]) { address in
        await attempts.record(address)
        return Self.response()
      }
    }
    #expect(await attempts.addresses.isEmpty)
    #expect(throws: WirePublicRecordQueryError.unavailable) {
      try WirePublicRecordAddressFallback.candidates([])
    }
  }

  @Test("a connection failure tries the second validated address once")
  func connectionFallbackSucceeds() async throws {
    let attempts = Attempts()
    let result = try await WirePublicRecordAddressFallback.run(
      addresses: ["2606:4700:4700::1111", "1.1.1.1"]
    ) { address in
      await attempts.record(address)
      if address == "1.1.1.1" { throw WirePublicRecordAddressFallback.Failure.connection }
      return Self.response()
    }
    #expect(result.status == 200)
    #expect(await attempts.addresses == ["1.1.1.1", "2606:4700:4700::1111"])
  }

  @Test("failed connections never expand beyond two validated addresses")
  func connectionAttemptsAreBounded() async {
    let attempts = Attempts()
    await #expect(throws: WirePublicRecordQueryError.unavailable) {
      try await WirePublicRecordAddressFallback.run(addresses: ["9.9.9.9", "8.8.8.8", "1.1.1.1"]) { address in
        await attempts.record(address)
        throw WirePublicRecordAddressFallback.Failure.connection
      }
    }
    #expect(await attempts.addresses == ["1.1.1.1", "8.8.8.8"])
  }

  @Test("HTTP responses do not trigger address retries", arguments: [200, 301, 404, 429, 503])
  func responsesNeverRetry(status: Int) async throws {
    let attempts = Attempts()
    let result = try await WirePublicRecordAddressFallback.run(addresses: ["1.1.1.1", "8.8.8.8"]) { address in
      await attempts.record(address)
      return Self.response(status: status)
    }
    #expect(result.status == status)
    #expect(await attempts.addresses == ["1.1.1.1"])
  }

  @Test("TLS, redirect, body and protocol errors propagate without fallback",
    arguments: ["tls", "redirect", "body", "protocol"])
  func semanticFailuresNeverRetry(kind: String) async {
    let attempts = Attempts()
    await #expect(throws: (any Error).self) {
      try await WirePublicRecordAddressFallback.run(addresses: ["1.1.1.1", "8.8.8.8"]) { address in
        await attempts.record(address)
        throw Self.failure(kind)
      }
    }
    #expect(await attempts.addresses == ["1.1.1.1"])
  }

  @Test("connection classification excludes certificate, protocol, cancellation and payload failures")
  func connectionClassification() {
    #expect(LiveWirePublicRecordHTTPTransport.isConnectionFailure(HTTPClientError.connectTimeout))
    #expect(LiveWirePublicRecordHTTPTransport.isConnectionFailure(HTTPClientError.remoteConnectionClosed))
    #expect(LiveWirePublicRecordHTTPTransport.isConnectionFailure(IOError(errnoCode: 61, reason: "fixture refused connection")))
    #expect(!LiveWirePublicRecordHTTPTransport.isConnectionFailure(
      IOError(errnoCode: 61, reason: "body stream connection closed"), receivedResponse: true))
    #expect(!LiveWirePublicRecordHTTPTransport.isConnectionFailure(
      HTTPClientError.readTimeout, receivedResponse: true))
    for error in [
      NIOSSLError.unableToValidateCertificate, NIOSSLError.uncleanShutdown,
      HTTPClientError.tlsHandshakeTimeout, HTTPClientError.bodyLengthMismatch,
      HTTPClientError.invalidProxyResponse, HTTPClientError.cancelled,
      WirePublicRecordQueryError.redirected, WirePublicRecordQueryError.responseTooLarge,
      WirePublicRecordQueryError.invalidResponse, CancellationError(),
    ] as [any Error] {
      #expect(!LiveWirePublicRecordHTTPTransport.isConnectionFailure(error))
    }
  }

  @Test("the overall deadline cancels a stuck attempt without trying another address")
  func deadlineCancelsAttempt() async {
    let attempts = Attempts()
    let started = ContinuousClock.now
    await #expect(throws: WirePublicRecordQueryError.unavailable) {
      try await WirePublicRecordAddressFallback.run(addresses: ["1.1.1.1", "8.8.8.8"], timeout: .milliseconds(50)) { address in
        await attempts.record(address)
        do { try await Task.sleep(for: .seconds(10)) }
        catch { await attempts.didCancel(); throw error }
        return Self.response()
      }
    }
    #expect(started.duration(to: .now) < .seconds(2))
    #expect(await attempts.addresses == ["1.1.1.1"])
    #expect(await attempts.cancelled)
  }

  @Test("caller cancellation stops the active request without fallback")
  func cancellationStopsAttempt() async {
    let attempts = Attempts()
    let task = Task {
      try await WirePublicRecordAddressFallback.run(addresses: ["1.1.1.1", "8.8.8.8"]) { address in
        await attempts.record(address)
        do { try await Task.sleep(for: .seconds(10)) }
        catch { await attempts.didCancel(); throw error }
        return Self.response()
      }
    }
    await attempts.waitUntilStarted()
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(await attempts.addresses == ["1.1.1.1"])
    #expect(await attempts.cancelled)
  }

  private static func response(status: Int = 200) -> WirePublicRecordHTTPResponse {
    WirePublicRecordHTTPResponse(status: status, body: Data("{}".utf8))
  }

  private static func failure(_ kind: String) -> any Error {
    switch kind {
    case "tls": NIOSSLError.unableToValidateCertificate
    case "redirect": WirePublicRecordQueryError.redirected
    case "body": WirePublicRecordQueryError.responseTooLarge
    default: HTTPClientError.bodyLengthMismatch
    }
  }

  private actor Attempts {
    private(set) var addresses: [String] = []
    private(set) var cancelled = false
    private var waiter: CheckedContinuation<Void, Never>?

    func record(_ address: String) {
      addresses.append(address)
      waiter?.resume()
      waiter = nil
    }

    func didCancel() { cancelled = true }

    func waitUntilStarted() async {
      if addresses.isEmpty {
        await withCheckedContinuation { waiter = $0 }
      }
    }
  }
}
