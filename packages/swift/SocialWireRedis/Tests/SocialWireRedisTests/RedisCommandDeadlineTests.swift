import Foundation
import Logging
import Testing
@testable import SocialWireRedis

@Suite("Redis command deadlines", .serialized)
struct RedisCommandDeadlineTests {
  @Test
  func blockedCommandRetiresConnectionAndAllowsRecovery() async throws {
    guard let url = ProcessInfo.processInfo.environment["REDIS_INTEGRATION_URL"] else { return }
    let client = try RediStackRedisClient(
      configuration: RedisConfiguration(
        url: url, maximumConnectionCount: 1, commandTimeoutMilliseconds: 100),
      logger: Logger(label: "redis.deadline.test"))
    let key = "deadline-test:\(UUID().uuidString)"
    let start = ContinuousClock.now
    do {
      _ = try await client.execute(command: "BLPOP", arguments: [.data(Data(key.utf8)), .integer(0)])
      Issue.record("An indefinitely blocked Redis command must time out")
    } catch {
      #expect(error is RedisCommandTimeoutError)
    }
    #expect(start.duration(to: .now) < .seconds(2))
    // The one leased connection was retired; recovery must acquire a new socket.
    try await client.ping()
    try await client.set(key, value: Data("recovered".utf8), expirationMilliseconds: 1_000)
    #expect(try await client.get(key) == Data("recovered".utf8))
    try await client.shutdown()
  }
}
