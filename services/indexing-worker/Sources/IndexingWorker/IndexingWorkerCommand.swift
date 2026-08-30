import ArgumentParser
import Foundation
import IndexingWorkerCore
import Logging

@main
@available(macOS 10.15, macCatalyst 13, iOS 13, tvOS 13, watchOS 6, *)
struct IndexingWorkerCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Run The Social Wire projection pool or singleton coordinator"
  )

  @Option(name: .long) var port: Int?
  @Option(name: .long) var hostname: String?

  mutating func run() async throws {
    var logger = Logger(label: "com.thesocialwire.indexing-worker")
    logger.logLevel = .info
    let environment = ProcessInfo.processInfo.environment
    let config = try IndexingWorkerConfig.load(
      environment,
      hostname: hostname,
      port: port
    )
    try await IndexingWorkerRuntime.run(
      environment: environment,
      config: config,
      logger: logger
    )
  }
}
