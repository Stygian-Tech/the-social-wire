import AsyncHTTPClient
import Foundation
import GatewayCore
import Hummingbird
import HummingbirdTesting
import Logging
import NIOCore
import Testing
@testable import Gateway

struct SportsCatalogProxySizeTests {
  @Test("complete public catalogs larger than eight MiB preserve every entity and feed", arguments: [
    "/xrpc/app.thesocialwire.discovery.getSportsCatalog",
    "/xrpc/app.thesocialwire.discovery.getFeedCatalog",
  ])
  func completeCatalog(path: String) async throws {
    let count = 14_000
    let entities = (0..<count).map { ["id":"team:\($0)", "name":String(repeating:"a", count:512), "kind":"team"] }
    let feeds = (0..<count).map { ["id":"entity:team:\($0)", "title":"Team \($0)", "kind":"team"] }
    let sports: [String: Any] = ["enabled":true,"available":true,"eventsEnabled":true,"entities":entities,"feeds":feeds,"version":"last-field-survives"]
    let responseObject: [String: Any] = path.hasSuffix("getFeedCatalog") ? ["sports": sports] : sports
    let payload = try JSONSerialization.data(withJSONObject: responseObject)
    #expect(payload.count > 8 * 1024 * 1024 && payload.count < 32 * 1024 * 1024)
    let upstream = Router()
    upstream.get(RouterPath(path)) { _, _ -> Response in
      Response(status:.ok, body:.init(byteBuffer:ByteBuffer(data:payload)))
    }
    try await proxy(upstream) { client in
      let reply = try await client.execute(uri:path, method:.get)
      #expect(reply.status == .ok)
      #expect(Data(buffer:reply.body) == payload)
      let root = try #require(JSONSerialization.jsonObject(with:Data(buffer:reply.body)) as? [String:Any])
      let result = path.hasSuffix("getFeedCatalog") ? try #require(root["sports"] as? [String:Any]) : root
      #expect((result["entities"] as? [[String:Any]])?.count == count)
      #expect((result["feeds"] as? [[String:Any]])?.count == count)
      #expect(result["version"] as? String == "last-field-survives")
    }
  }

  @Test("catalog bounds remain finite and oversized upstream bodies return safe 502", arguments: [
    "/xrpc/app.thesocialwire.discovery.getSportsCatalog",
    "/xrpc/app.thesocialwire.discovery.getFeedCatalog",
    "/xrpc/app.thesocialwire.discovery.getSports",
  ])
  func oversizedUpstream(path: String) async throws {
    let limit = WireProxyRoutes.maximumResponseBytes(for:path)
    #expect(limit == (path.hasSuffix("Catalog") ? 32 : 8) * 1024 * 1024)
    let chunk = ByteBuffer(repeating:UInt8(ascii:"a"), count:1024 * 1024)
    let upstream = Router()
    upstream.get(RouterPath(path)) { _, _ -> Response in
      Response(status:.ok, body:ResponseBody { writer in
        for _ in 0...(limit / chunk.readableBytes) { try await writer.write(chunk) }
        try await writer.finish(nil)
      })
    }
    try await proxy(upstream) { client in
      let reply = try await client.execute(uri:path, method:.get)
      #expect(reply.status == .badGateway)
      let body = String(buffer:reply.body)
      #expect(body.contains("The Wire is temporarily unavailable"))
      #expect(!body.contains("NIOTooManyBytesError") && !body.contains("8388608"))
    }
  }

  @Test func otherWireRoutesRetainEightMiBBound() {
    for path in WireProxyRoutes.paths where !["/xrpc/app.thesocialwire.discovery.getSportsCatalog", "/xrpc/app.thesocialwire.discovery.getFeedCatalog"].contains(path) {
      #expect(WireProxyRoutes.maximumResponseBytes(for:path) == 8 * 1024 * 1024)
    }
  }

  private func proxy(_ upstream: Router<BasicRequestContext>, body: @Sendable (any TestClientProtocol) async throws -> Void) async throws {
    let http = HTTPClient(eventLoopGroupProvider:.singleton)
    do {
      try await Application(router:upstream).test(.live) { server in
        let port = try #require(server.port)
        let router = Router(context:GatewayRequestContext.self)
        WireProxyRoutes(baseURL:"http://localhost:\(port)", internalSecret:nil, httpClient:http,
          limiter:WireRequestLimiter(), logger:Logger(label:"sports-catalog-size.test")).register(on:router.group())
        try await Application(router:router).test(.live) { client in try await body(client) }
      }
    } catch { try? await http.shutdown(); throw error }
    try await http.shutdown()
  }
}
