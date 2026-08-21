import GatewayCore
import Testing

@Suite("Optional ATProto authentication")
struct OptionalATProtoAuthMiddlewareTests {
  @Test("Only a request with no credential material is anonymous")
  func classification() {
    #expect(OptionalATProtoAuthMiddleware.decision(hasAuthorization: false, hasDPoP: false) == .anonymous)
    #expect(OptionalATProtoAuthMiddleware.decision(hasAuthorization: true, hasDPoP: false) == .verify)
    #expect(OptionalATProtoAuthMiddleware.decision(hasAuthorization: false, hasDPoP: true) == .verify)
    #expect(OptionalATProtoAuthMiddleware.decision(hasAuthorization: true, hasDPoP: true) == .verify)
  }
}
