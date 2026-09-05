import Foundation
import Testing

@testable import OperationsCore

@Suite("Metric batch aggregation")
struct OperationsMetricBatchTests {
  @Test("coalescing retains count sum extrema and minute bucket")
  func preservesStatistics() {
    var batch = OperationsMetricBatch(
      sample: .init(name: "latency", value: 4, dimensions: [:],
                    recordedAt: Date(timeIntervalSince1970: 125)),
      dimensionsJSON: "{}", dimensionsHash: "scope")
    batch.add(-2)
    batch.add(10)
    #expect(batch.count == 3)
    #expect(batch.sum == 12)
    #expect(batch.minimum == -2)
    #expect(batch.maximum == 10)
    #expect(batch.bucket == Date(timeIntervalSince1970: 120))
  }

  @Test("different minutes, names and dimensions never coalesce")
  func separatesKeys() {
    func key(_ name: String, _ time: Double, _ dimensions: String) -> String {
      OperationsMetricBatch(
        sample: .init(name: name, value: 1, dimensions: [:],
                      recordedAt: Date(timeIntervalSince1970: time)),
        dimensionsJSON: "{}", dimensionsHash: dimensions).key
    }
    #expect(key("a", 120, "x") == key("a", 179, "x"))
    #expect(Set([key("a", 120, "x"), key("b", 120, "x"),
                 key("a", 180, "x"), key("a", 120, "y")]).count == 4)
  }
}
