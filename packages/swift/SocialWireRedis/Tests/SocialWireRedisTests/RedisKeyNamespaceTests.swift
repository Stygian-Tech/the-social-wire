import Testing
@testable import SocialWireRedis

@Suite("Redis key namespace")
struct RedisKeyNamespaceTests {
  @Test
  func hashesIdentifiersAndSeparatesEnvironments() {
    let namespace = RedisKeyNamespace(environment: "Development")
    let key = namespace.key(domain: "sidebar", identifiers: ["did:plc:alice"])

    #expect(key.hasPrefix("sw:development:v1:sidebar:"))
    #expect(!key.contains("did:plc:alice"))
    #expect(key.split(separator: ":").last?.count == 64)
    #expect(key != RedisKeyNamespace(environment: "production").key(
      domain: "sidebar",
      identifiers: ["did:plc:alice"]
    ))
  }

  @Test
  func preservesOnlyBoundedKeyComponents() {
    let namespace = RedisKeyNamespace(environment: "dev")
    let key = namespace.key(
      domain: "lock",
      safeComponents: ["firstpage"],
      identifiers: ["at://did:plc:alice/site.standard.publication/main"]
    )

    #expect(key.hasPrefix("sw:dev:v1:lock:firstpage:"))
    #expect(!key.contains("did:plc:alice"))
    #expect(key.split(separator: ":").last?.count == 64)
  }

  @Test
  func hashesUnsafeValuesPassedAsNominallySafeComponents() {
    let namespace = RedisKeyNamespace(environment: "dev")
    let raw = "https://private.example/users/alice"
    let key = namespace.key(domain: "rank", safeComponents: [raw, "24h"])

    #expect(!key.contains("private"))
    #expect(key.contains(RedisKeyNamespace.digest(raw)))
  }
}
