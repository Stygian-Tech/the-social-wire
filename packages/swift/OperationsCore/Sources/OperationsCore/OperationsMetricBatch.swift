import Foundation

/// One SQL rollup update per persisted key, preserving every sample's weight.
struct OperationsMetricBatch: Sendable {
  let name: String
  let bucket: Date
  let dimensionsJSON: String
  let dimensionsHash: String
  private(set) var count: Int64 = 1
  private(set) var sum: Double
  private(set) var minimum: Double
  private(set) var maximum: Double

  init(sample: OperationsMetricSample, dimensionsJSON: String, dimensionsHash: String) {
    name = String(sample.name.prefix(160))
    bucket = Date(timeIntervalSince1970: floor(sample.recordedAt.timeIntervalSince1970 / 60) * 60)
    self.dimensionsJSON = dimensionsJSON
    self.dimensionsHash = dimensionsHash
    sum = sample.value
    minimum = sample.value
    maximum = sample.value
  }

  var key: String { "\(bucket.timeIntervalSince1970)|\(name)|\(dimensionsHash)" }

  mutating func add(_ value: Double) {
    count += 1
    sum += value
    minimum = min(minimum, value)
    maximum = max(maximum, value)
  }
}
