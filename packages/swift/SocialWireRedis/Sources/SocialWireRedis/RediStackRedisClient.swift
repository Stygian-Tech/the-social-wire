@preconcurrency import RediStack
import Foundation
import Logging
import NIOCore
import NIOPosix
@preconcurrency import NIOSSL

public actor RediStackRedisClient: RedisCommandClient {
  private let eventLoopGroup: MultiThreadedEventLoopGroup
  private let pool: RedisConnectionPool
  private let commandTimeout: Duration
  private let telemetry: RedisTelemetrySink?
  private let logger: Logger
  private let redisHost: String
  private let redisPort: Int
  private var resolvedAddress: SocketAddress
  private var addressRefreshState = RedisAddressRefreshState()
  private var lastFailureLogAt = Date.distantPast
  private static let failureLogCooldown: TimeInterval = 60

  public init(
    configuration: RedisConfiguration,
    logger: Logger,
    telemetry: RedisTelemetrySink? = nil
  ) throws {
    let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let address = try SocketAddress.makeAddressResolvingHost(
      configuration.host,
      port: configuration.port
    )
    let bootstrap: ClientBootstrap?
    if configuration.usesTLS {
      var tlsConfiguration = TLSConfiguration.makeClientConfiguration()
      tlsConfiguration.certificateVerification = .fullVerification
      let context = try NIOSSLContext(configuration: tlsConfiguration)
      bootstrap = ClientBootstrap(group: eventLoopGroup)
        .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
        .channelInitializer { channel in
          do {
            let tlsHandler = try NIOSSLClientHandler(
              context: context,
              serverHostname: configuration.host
            )
            try channel.pipeline.syncOperations.addHandler(tlsHandler)
            return channel.pipeline.addBaseRedisHandlers()
          } catch {
            return channel.eventLoop.makeFailedFuture(error)
          }
        }
    } else {
      bootstrap = nil
    }
    var poolLogger = logger
    poolLogger.logLevel = .critical
    let factory = RedisConnectionPool.ConnectionFactoryConfiguration(
      connectionInitialDatabase: configuration.database,
      connectionUsername: configuration.username,
      connectionPassword: configuration.password,
      connectionDefaultLogger: poolLogger,
      tcpClient: bootstrap
    )
    let poolConfiguration = RedisConnectionPool.Configuration(
      initialServerConnectionAddresses: [address],
      maximumConnectionCount: .maximumActiveConnections(configuration.maximumConnectionCount),
      connectionFactoryConfiguration: factory,
      minimumConnectionCount: configuration.minimumConnectionCount,
      connectionBackoffFactor: 2,
      initialConnectionBackoffDelay: .milliseconds(100),
      connectionRetryTimeout: .milliseconds(Int64(configuration.commandTimeoutMilliseconds)),
      poolDefaultLogger: poolLogger
    )
    self.eventLoopGroup = eventLoopGroup
    self.commandTimeout = .milliseconds(configuration.commandTimeoutMilliseconds)
    self.telemetry = telemetry
    self.logger = logger
    self.redisHost = configuration.host
    self.redisPort = configuration.port
    self.resolvedAddress = address
    self.pool = RedisConnectionPool(
      configuration: poolConfiguration,
      boundEventLoop: eventLoopGroup.next()
    )
    pool.activate(logger: poolLogger)
  }

  public func get(_ key: String) async throws -> Data? {
    let response = try await measured(operation: "get") {
      try await self.pool.get(RedisKey(key)).get()
    }
    return response.data
  }

  public func set(_ key: String, value: Data, expirationMilliseconds: Int) async throws {
    _ = try await measured(operation: "set") {
      try await self.pool.set(
        RedisKey(key),
        to: value,
        onCondition: .none,
        expiration: .milliseconds(expirationMilliseconds)
      ).get()
    }
  }

  public func setIfAbsent(
    _ key: String,
    value: Data,
    expirationMilliseconds: Int
  ) async throws -> Bool {
    let result = try await measured(operation: "set_nx") {
      try await self.pool.set(
        RedisKey(key),
        to: value,
        onCondition: .keyDoesNotExist,
        expiration: .milliseconds(expirationMilliseconds)
      ).get()
    }
    return result == .ok
  }

  public func delete(_ keys: [String]) async throws -> Int {
    let response = try await measured(operation: "unlink") {
      try await self.pool.send(
        command: "UNLINK",
        with: keys.map { RESPValue(from: $0) }
      ).get()
    }
    return response.int ?? 0
  }

  public func execute(
    command: String,
    arguments: [RedisCommandValue]
  ) async throws -> RedisCommandValue {
    let operation = command.lowercased()
    let response = try await measured(operation: operation) {
      let response = try await self.pool.send(
        command: command,
        with: arguments.map(Self.respValue)
      ).get()
      if case .error = response { throw RedisServerError() }
      return response
    }
    return Self.commandValue(response)
  }

  public func ping() async throws {
    _ = try await measured(operation: "ping") {
      try await self.pool.send(command: "PING").get()
    }
  }

  public func shutdown() async throws {
    let promise = pool.eventLoop.makePromise(of: Void.self)
    pool.close(promise: promise)
    try await promise.futureResult.get()
    try await eventLoopGroup.shutdownGracefully()
  }

  private func bounded<Value: Sendable>(
    operation: @escaping @Sendable () async throws -> Value
  ) async throws -> Value {
    try await withThrowingTaskGroup(of: Value.self) { group in
      group.addTask { try await operation() }
      group.addTask {
        try await Task.sleep(for: self.commandTimeout)
        throw RedisCommandTimeoutError()
      }
      guard let result = try await group.next() else { throw RedisCommandTimeoutError() }
      group.cancelAll()
      return result
    }
  }

  private func measured<Value: Sendable>(
    operation: String,
    body: @escaping @Sendable () async throws -> Value
  ) async throws -> Value {
    let startedAt = Date()
    do {
      let value = try await bounded(operation: body)
      telemetry?(.init(
        kind: .operation,
        operation: operation,
        outcome: "success",
        durationMilliseconds: Date().timeIntervalSince(startedAt) * 1_000
      ))
      return value
    } catch {
      telemetry?(.init(
        kind: .error,
        operation: operation,
        outcome: error is RedisCommandTimeoutError ? "timeout" : "command_failed"
      ))
      let now = Date()
      refreshConnectionAddressIfNeeded(now: now)
      if now.timeIntervalSince(lastFailureLogAt) >= Self.failureLogCooldown {
        lastFailureLogAt = now
        logger.warning("Redis unavailable; cache command failed", metadata: [
          "operation": .string(operation),
          "error_type": .string(String(describing: type(of: error)).lowercased()),
        ])
      }
      throw error
    }
  }

  private func refreshConnectionAddressIfNeeded(now: Date) {
    guard addressRefreshState.beginRefreshIfAllowed(now: now) else { return }
    do {
      let address = try SocketAddress.makeAddressResolvingHost(redisHost, port: redisPort)
      guard address != resolvedAddress else { return }
      resolvedAddress = address
      pool.updateConnectionAddresses([address])
      logger.info("Redis connection target refreshed after command failure")
    } catch {
      logger.debug("Redis connection target refresh failed", metadata: [
        "error_type": .string(String(describing: type(of: error)).lowercased()),
      ])
    }
  }

  private static func respValue(_ value: RedisCommandValue) -> RESPValue {
    switch value {
    case .null:
      .null
    case .data(let data):
      RESPValue(from: data)
    case .integer(let integer):
      RESPValue(from: integer)
    case .array(let values):
      .array(values.map(respValue))
    }
  }

  private static func commandValue(_ value: RESPValue) -> RedisCommandValue {
    switch value {
    case .null, .bulkString(nil):
      .null
    case .simpleString, .bulkString:
      value.data.map(RedisCommandValue.data) ?? .null
    case .integer(let integer):
      .integer(integer)
    case .array(let values):
      .array(values.map(commandValue))
    case .error(let error):
      .data(Data(error.message.utf8))
    }
  }
}

struct RedisAddressRefreshState: Sendable {
  private(set) var lastAttemptAt = Date.distantPast
  let cooldown: TimeInterval

  init(cooldown: TimeInterval = 5) {
    self.cooldown = cooldown
  }

  mutating func beginRefreshIfAllowed(now: Date) -> Bool {
    guard now.timeIntervalSince(lastAttemptAt) >= cooldown else { return false }
    lastAttemptAt = now
    return true
  }
}
