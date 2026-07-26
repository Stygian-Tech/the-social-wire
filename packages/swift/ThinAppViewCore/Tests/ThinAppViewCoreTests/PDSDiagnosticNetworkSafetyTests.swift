import AsyncHTTPClient
import Foundation
import NIOCore
import NIOHTTP1
import Testing

@testable import ThinAppViewCore

@Suite("PDS diagnostic network safety")
struct PDSDiagnosticNetworkSafetyTests {
  @Test("production endpoints require public HTTPS hostnames")
  func publicEndpointValidation() {
    #expect(
      PDSResolvedEndpointValidator.validatedBase(
        "https://pds.thesocialwire.social/",
        policy: .publicHTTPS
      ) == "https://pds.thesocialwire.social"
    )

    for endpoint in [
      "http://pds.thesocialwire.social",
      "https://localhost",
      "https://pds.localhost",
      "https://127.0.0.1",
      "https://10.0.0.1",
      "https://169.254.169.254",
      "https://8.8.8.8",
      "https://[::1]",
      "https://metadata.google.internal",
      "https://pds.example.test",
      "https://user:password@pds.thesocialwire.social",
      "https://pds.thesocialwire.social?redirect=http://127.0.0.1",
    ] {
      #expect(
        PDSResolvedEndpointValidator.validatedBase(endpoint, policy: .publicHTTPS) == nil,
        "unexpectedly accepted \(endpoint)"
      )
    }
  }

  @Test("loopback is available only through the explicit local-test policy")
  func localTestEndpointValidation() {
    #expect(
      PDSResolvedEndpointValidator.validatedBase(
        "http://127.0.0.1:8080/",
        policy: .localTesting
      ) == "http://127.0.0.1:8080"
    )
    #expect(
      PDSResolvedEndpointValidator.validatedBase(
        "http://localhost:8080",
        policy: .publicHTTPS
      ) == nil
    )
    #expect(
      PDSResolvedEndpointValidator.validatedBase(
        "http://192.168.1.10:8080",
        policy: .localTesting
      ) == nil
    )
  }

  @Test("DID resolution rejects an unsafe PDS service endpoint")
  func resolutionRejectsUnsafeEndpoint() async {
    let transport = StubPDSHTTPTransport(
      responses: [
        Self.response(
          status: .ok,
          body: ##"{"service":[{"id":"#atproto_pds","type":"AtprotoPersonalDataServer","serviceEndpoint":"http://127.0.0.1:3000"}]}"##
        )
      ]
    )

    await #expect(throws: ThinAppViewPdsResolutionError.unsafeServiceEndpoint) {
      _ = try await ThinAppViewPdsResolution.resolvePdsBase(
        repoDid: "did:plc:aaaaaaaaaaaaaaaaaaaaaaaa",
        plcBase: "https://plc.directory",
        transport: transport,
        endpointPolicy: .publicHTTPS
      )
    }
  }

  @Test("non-success response bodies are consumed only to the configured bound")
  func boundedErrorBodyDrain() async throws {
    let probe = ResponseBodyProbe()
    let body = HTTPClientResponse.Body.stream(
      ProbedBodySequence(probe: probe, chunkSize: 40 * 1_024, chunkCount: 3)
    )

    try await HTTPResponseBodyDrain.drainOrCancel(body, upTo: 64 * 1_024)

    #expect(await probe.readCount == 2)
  }

  @Test("rate limiter suspension propagates task cancellation")
  func limiterCancellation() async throws {
    let limiter = PDSRequestRateLimiter(requestsPerSecond: 1)
    try await limiter.waitForPermit()
    let waiting = Task { try await limiter.waitForPermit() }
    waiting.cancel()

    await #expect(throws: CancellationError.self) {
      try await waiting.value
    }
  }

  @Test("DID resolution transport cancellation is not converted into a missing PDS")
  func resolutionCancellation() async {
    let transport = CancellingPDSHTTPTransport()
    let resolution = Task {
      try await ThinAppViewPdsResolution.resolvePdsBase(
        repoDid: "did:plc:aaaaaaaaaaaaaaaaaaaaaaaa",
        plcBase: "https://plc.directory",
        transport: transport,
        endpointPolicy: .publicHTTPS
      )
    }
    resolution.cancel()

    await #expect(throws: CancellationError.self) {
      _ = try await resolution.value
    }
  }

  private static func response(
    status: HTTPResponseStatus,
    body: String
  ) -> HTTPClientResponse {
    var buffer = ByteBufferAllocator().buffer(capacity: body.utf8.count)
    buffer.writeString(body)
    return HTTPClientResponse(status: status, body: .bytes(buffer))
  }
}

@Suite("PDS listRecords cursor safety")
struct PDSListRecordsCursorSafetyTests {
  @Test("missing cursor ends pagination and valid cursors advance")
  func validCursorStates() {
    #expect(
      PDSListRecordsCursor.parse(json: [:], current: nil, seen: [], pageIsEmpty: false)
        == .end
    )
    #expect(
      PDSListRecordsCursor.parse(
        json: ["cursor": "page-2"],
        current: nil,
        seen: [],
        pageIsEmpty: false
      ) == .next("page-2")
    )
  }

  @Test("malformed, empty, repeated, cyclic, and empty-page cursors are rejected")
  func invalidCursorStates() {
    #expect(
      PDSListRecordsCursor.parse(
        json: ["cursor": 2], current: nil, seen: [], pageIsEmpty: false
      ) == .invalid("cursor_not_string")
    )
    #expect(
      PDSListRecordsCursor.parse(
        json: ["cursor": "  "], current: nil, seen: [], pageIsEmpty: false
      ) == .invalid("cursor_empty")
    )
    #expect(
      PDSListRecordsCursor.parse(
        json: ["cursor": "page-2"],
        current: "page-2",
        seen: ["page-2"],
        pageIsEmpty: false
      ) == .invalid("cursor_cycle")
    )
    #expect(
      PDSListRecordsCursor.parse(
        json: ["cursor": "page-1"],
        current: "page-2",
        seen: ["page-1", "page-2"],
        pageIsEmpty: false
      ) == .invalid("cursor_cycle")
    )
    #expect(
      PDSListRecordsCursor.parse(
        json: ["cursor": "page-2"], current: nil, seen: [], pageIsEmpty: true
      ) == .invalid("empty_page_with_cursor")
    )
  }
}

private actor StubPDSHTTPTransport: PDSHTTPTransport {
  private var responses: [HTTPClientResponse]

  init(responses: [HTTPClientResponse]) {
    self.responses = responses
  }

  func execute(
    _ request: HTTPClientRequest,
    timeout: TimeAmount
  ) async throws -> HTTPClientResponse {
    _ = request
    _ = timeout
    return responses.removeFirst()
  }
}

private struct CancellingPDSHTTPTransport: PDSHTTPTransport {
  func execute(
    _ request: HTTPClientRequest,
    timeout: TimeAmount
  ) async throws -> HTTPClientResponse {
    _ = request
    _ = timeout
    try await Task.sleep(for: .seconds(60))
    return HTTPClientResponse()
  }
}

private actor ResponseBodyProbe {
  private(set) var readCount = 0

  func recordRead() {
    readCount += 1
  }
}

private struct ProbedBodySequence: AsyncSequence, Sendable {
  typealias Element = ByteBuffer

  struct AsyncIterator: AsyncIteratorProtocol {
    let probe: ResponseBodyProbe
    let chunkSize: Int
    let chunkCount: Int
    var index = 0

    mutating func next() async throws -> ByteBuffer? {
      guard index < chunkCount else { return nil }
      index += 1
      await probe.recordRead()
      var buffer = ByteBufferAllocator().buffer(capacity: chunkSize)
      buffer.writeRepeatingByte(0x61, count: chunkSize)
      return buffer
    }
  }

  let probe: ResponseBodyProbe
  let chunkSize: Int
  let chunkCount: Int

  func makeAsyncIterator() -> AsyncIterator {
    AsyncIterator(probe: probe, chunkSize: chunkSize, chunkCount: chunkCount)
  }
}
