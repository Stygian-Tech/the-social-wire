import Foundation

public struct RedisInfoSampler: Sendable {
  private let commands: any RedisCommandClient
  private let telemetry: RedisTelemetrySink?

  public init(commands: any RedisCommandClient, telemetry: RedisTelemetrySink?) {
    self.commands = commands
    self.telemetry = telemetry
  }

  public func sample() async throws {
    let stats = try await info(section: "stats")
    let memory = try await info(section: "memory")
    emit(name: "expired_keys", value: stats["expired_keys"])
    emit(name: "evicted_keys", value: stats["evicted_keys"])
    emit(name: "memory_used_bytes", value: memory["used_memory"])
  }

  public func runForever(interval: Duration = .seconds(60)) async {
    while !Task.isCancelled {
      try? await sample()
      try? await Task.sleep(for: interval)
    }
  }

  private func info(section: String) async throws -> [String: Double] {
    let response = try await commands.execute(
      command: "INFO",
      arguments: [.data(Data(section.utf8))]
    )
    guard let text = response.string else { return [:] }
    var values: [String: Double] = [:]
    for line in text.split(whereSeparator: \Character.isNewline) {
      guard !line.hasPrefix("#"),
            let separator = line.firstIndex(of: ":"),
            let value = Double(line[line.index(after: separator)...])
      else { continue }
      values[String(line[..<separator])] = value
    }
    return values
  }

  private func emit(name: String, value: Double?) {
    guard let value, value.isFinite, value >= 0 else { return }
    telemetry?(.init(
      kind: .resourceSample,
      operation: name,
      outcome: "sample",
      value: value
    ))
  }
}
