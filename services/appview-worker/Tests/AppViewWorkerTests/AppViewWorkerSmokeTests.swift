import AsyncHTTPClient
import NIOCore
import Testing

@testable import AppViewWorker

@Test("Charybdis package resolves through the stable AppViewWorker product")
func charybdisPackageResolves() {
  #expect(true)
}

@Test("Charybdis bounds stalled response bodies without capping the ingestion pool at eight")
func charybdisHTTPClientConfiguration() {
  let configuration = CharybdisCommand.httpClientConfiguration()

  #expect(configuration.timeout.read == .seconds(30))
  #expect(configuration.connectionPool.concurrentHTTP1ConnectionsPerHostSoftLimit == 50)
}
