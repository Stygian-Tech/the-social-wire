import Foundation
import Testing

@testable import WireWorkerCore

@Suite("Wire materialization scheduling")
struct WireWorkerSchedulingTests {
  @Test("cycle work consumes the interval, while overruns never build a timer backlog")
  func elapsedTimeCadence() {
    #expect(WireGenerationSchedule.remainingDelay(interval: .seconds(300), elapsed: .seconds(45)) == .seconds(255))
    #expect(WireGenerationSchedule.remainingDelay(interval: .seconds(300), elapsed: .seconds(300)) == .zero)
    #expect(WireGenerationSchedule.remainingDelay(interval: .seconds(300), elapsed: .seconds(725)) == .zero)
  }

}
