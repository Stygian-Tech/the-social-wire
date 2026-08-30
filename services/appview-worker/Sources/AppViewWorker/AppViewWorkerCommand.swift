import AppViewWorkerCore
import ArgumentParser
import Logging
import ThinAppViewCore

@main
@available(macOS 10.15, macCatalyst 13, iOS 13, tvOS 13, watchOS 6, *)
struct CharybdisCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Charybdis, The Social Wire ingestion service"
  )

  @Option(name: .long) var port: Int?
  @Option(name: .long) var hostname: String?

  mutating func run() async throws {
    var logger = Logger(label: "com.thesocialwire.appview-worker")
    logger.logLevel = .info

    try await AppViewWorkerHost.run(
      environment: RuntimeEnvironment.mergeProcessWithDotenv(),
      role: .combined,
      healthListener: .enabled(hostname: hostname, port: port),
      logger: logger
    )
  }
}
