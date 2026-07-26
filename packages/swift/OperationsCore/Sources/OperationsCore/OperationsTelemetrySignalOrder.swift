import Foundation

enum OperationsTelemetrySignalOrder {
  static func sorted(_ signals: [OperationsTelemetrySignal]) -> [OperationsTelemetrySignal] {
    signals.sorted { key(for: $0) < key(for: $1) }
  }

  private static func key(for signal: OperationsTelemetrySignal) -> String {
    switch signal {
    case .metric(let sample):
      let dimensions = OperationsRedactor.boundedAttributes(sample.dimensions)
      let dimensionIdentity = dimensions.sorted { $0.key < $1.key }
        .map { "\($0.key)=\($0.value)" }
        .joined(separator: "&")
      let dimensionsHash = OperationsRedactor.hashIdentity(dimensionIdentity)
      let bucket = floor(sample.recordedAt.timeIntervalSince1970 / 60) * 60
      return "0|\(bucket)|\(String(sample.name.prefix(160)))|\(dimensionsHash)"
    case .event(let event):
      return "1|\(event.environment)|\(event.id)"
    case .span(let span):
      return "2|\(span.environment)|\(span.id)"
    }
  }
}
