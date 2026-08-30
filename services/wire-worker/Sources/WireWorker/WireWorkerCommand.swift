import ArgumentParser
import Foundation
import Logging
import WireWorkerCore

@main
@available(macOS 10.15, macCatalyst 13, iOS 13, tvOS 13, watchOS 6, *)
struct WireWorkerCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Materialize The Wire"
  )

  @Option(name: .long) var port: Int?
  @Option(name: .long) var hostname: String?

  mutating func run() async throws {
    LoggingSystem.bootstrap { RailwaySeverityLogHandler(label: $0) }
    var logger = Logger(label: "com.thesocialwire.wire-worker")
    logger.logLevel = .info
    let environment = ProcessInfo.processInfo.environment
    let host = hostname ?? environment["BIND_HOST"] ?? "::"
    let port = port ?? Int(environment["PORT"] ?? "8080") ?? 8080
    try await WireWorkerHost.run(
      environment: environment,
      healthListener: .enabled(hostname: host, port: port),
      logger: logger
    )
  }
}
