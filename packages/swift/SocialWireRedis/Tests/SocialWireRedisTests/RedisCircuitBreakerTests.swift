import Foundation
import Testing
@testable import SocialWireRedis

@Suite("Redis circuit breaker")
struct RedisCircuitBreakerTests {
  @Test
  func opensAndAllowsOneHalfOpenProbe() async {
    let breaker = RedisCircuitBreaker(
      failureThreshold: 3,
      initialOpenDuration: 5,
      maximumOpenDuration: 30
    )
    let now = Date(timeIntervalSince1970: 1_000)
    await breaker.recordFailure(at: now)
    await breaker.recordFailure(at: now)
    await breaker.recordFailure(at: now)

    #expect(await breaker.state(at: now) == .open)
    #expect(!(await breaker.permit(at: now)))
    #expect(await breaker.permit(at: now.addingTimeInterval(5)))
    #expect(!(await breaker.permit(at: now.addingTimeInterval(5))))

    await breaker.recordSuccess()
    #expect(await breaker.state(at: now) == .closed)
  }

  @Test
  func repeatedProbeFailuresBackOffToTheBound() async {
    let breaker = RedisCircuitBreaker(
      failureThreshold: 1,
      initialOpenDuration: 5,
      maximumOpenDuration: 30
    )
    let start = Date(timeIntervalSince1970: 2_000)
    await breaker.recordFailure(at: start)
    #expect(await breaker.permit(at: start.addingTimeInterval(5)))
    await breaker.recordFailure(at: start.addingTimeInterval(5))
    #expect(await breaker.state(at: start.addingTimeInterval(14)) == .open)
    #expect(await breaker.state(at: start.addingTimeInterval(15)) == .halfOpen)

    await breaker.recordFailure(at: start.addingTimeInterval(15))
    await breaker.recordFailure(at: start.addingTimeInterval(35))
    #expect(await breaker.state(at: start.addingTimeInterval(64)) == .open)
    #expect(await breaker.state(at: start.addingTimeInterval(65)) == .halfOpen)
  }
}
