import FinanceCore
import Logging
import Testing
import WireCore
@testable import WireWorkerCore

struct FinanceProjectionRuntimeTests {
  @Test("Finance article analysis belongs to Projection Pool and respects independent gates")
  func roleOwnership() {
    for role in WireWorkerRole.allCases {
      let enabled = WireWorkerRuntimePlan(mode: .api, role: role, cleanupEnabled: true,
        financeMode: .shadow, financeRightsConfirmed: true)
      #expect(enabled.runsFinanceProjection == (role != .rank))
      #expect(!WireWorkerRuntimePlan(mode: .api, role: role, cleanupEnabled: true).runsFinanceProjection)
      #expect(!WireWorkerRuntimePlan(mode: .api, role: role, cleanupEnabled: true,
        financeMode: .api, financeRightsConfirmed: false).runsFinanceProjection)
    }
    #expect(PostgresFinanceArticleProjector.batchLimit == 25)
  }

  @Test("Finance projection retries independently and propagates cancellation")
  func failureIsolation() async throws {
    let counter = ProjectionCounter()
    try await FinanceArticleProjectionRuntime.runScheduled(operation: {
      await counter.increment()
      throw ProjectionFailure.unavailable
    }, logger: Logger(label: "finance-projection.test"), sleep: {}, iterationLimit: 2)
    #expect(await counter.count == 2)
    await #expect(throws: CancellationError.self) {
      try await FinanceArticleProjectionRuntime.runScheduled(operation: { throw CancellationError() },
        logger: Logger(label: "finance-projection.test"), sleep: {}, iterationLimit: 2)
    }
  }
}

private actor ProjectionCounter {
  var count = 0
  func increment() { count += 1 }
}
private enum ProjectionFailure: Error { case unavailable }
