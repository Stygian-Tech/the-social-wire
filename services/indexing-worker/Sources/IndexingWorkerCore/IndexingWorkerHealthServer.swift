import Logging
import NIOCore
import NIOHTTP1
import NIOPosix

enum IndexingWorkerHealthServer {
  static func run(
    role: IndexingWorkerRole,
    startupProbe: @escaping @Sendable () async throws -> Void,
    readinessProbe: @escaping @Sendable () async throws -> Void,
    host: String,
    port: Int,
    logger: Logger
  ) async throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let channel = try await ServerBootstrap(group: group)
      .serverChannelOption(ChannelOptions.backlog, value: 64)
      .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
      .childChannelInitializer { channel in
        channel.pipeline.configureHTTPServerPipeline().flatMap {
          channel.pipeline.addHandler(
            IndexingWorkerHealthRequestHandler(
              role: role,
              startupProbe: startupProbe,
              readinessProbe: readinessProbe
            )
          )
        }
      }
      .bind(host: host, port: port)
      .get()

    logger.info(
      "Indexing worker health server listening",
      metadata: ["host": .string(host), "port": .string(String(port)), "role": .string(role.rawValue)]
    )
    try await withTaskCancellationHandler {
      try await channel.closeFuture.get()
    } onCancel: {
      channel.close(promise: nil)
    }
    try await group.shutdownGracefully()
  }
}

struct IndexingWorkerHealthResponseBuilder {
  struct Response: Sendable, Equatable {
    let status: HTTPResponseStatus
    let body: String
  }

  static func response(
    method: HTTPMethod,
    uri: String,
    role: IndexingWorkerRole,
    startupProbe: @escaping @Sendable () async throws -> Void,
    readinessProbe: @escaping @Sendable () async throws -> Void
  ) async -> Response {
    guard method == .GET else {
      return .init(status: .methodNotAllowed, body: #"{"error":"method_not_allowed"}"#)
    }
    let path = uri.split(separator: "?", maxSplits: 1).first.map(String.init) ?? uri
    switch path {
    case "/health", "/livez":
      return healthy(role: role, status: "live")
    case "/startupz":
      return await probed(role: role, healthyStatus: "started", probe: startupProbe)
    case "/readyz":
      return await probed(role: role, healthyStatus: "ready", probe: readinessProbe)
    default:
      return .init(status: .notFound, body: #"{"error":"not_found"}"#)
    }
  }

  private static func probed(
    role: IndexingWorkerRole,
    healthyStatus: String,
    probe: @escaping @Sendable () async throws -> Void
  ) async -> Response {
    do {
      try await probe()
      return healthy(role: role, status: healthyStatus)
    } catch {
      return .init(
        status: .serviceUnavailable,
        body: body(role: role, status: "unavailable")
      )
    }
  }

  private static func healthy(role: IndexingWorkerRole, status: String) -> Response {
    .init(status: .ok, body: body(role: role, status: status))
  }

  private static func body(role: IndexingWorkerRole, status: String) -> String {
    #"{"service":"indexing-worker","role":"\#(role.rawValue)","status":"\#(status)"}"#
  }
}

private final class IndexingWorkerHealthRequestHandler: ChannelInboundHandler, @unchecked Sendable {
  typealias InboundIn = HTTPServerRequestPart
  typealias OutboundOut = HTTPServerResponsePart

  private let role: IndexingWorkerRole
  private let startupProbe: @Sendable () async throws -> Void
  private let readinessProbe: @Sendable () async throws -> Void
  private var requestHead: HTTPRequestHead?

  init(
    role: IndexingWorkerRole,
    startupProbe: @escaping @Sendable () async throws -> Void,
    readinessProbe: @escaping @Sendable () async throws -> Void
  ) {
    self.role = role
    self.startupProbe = startupProbe
    self.readinessProbe = readinessProbe
  }

  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    switch unwrapInboundIn(data) {
    case .head(let head): requestHead = head
    case .body: break
    case .end:
      guard let head = requestHead else {
        context.close(promise: nil)
        return
      }
      requestHead = nil
      let loopBoundContext = context.loopBound
      let loopBoundSelf = NIOLoopBound(self, eventLoop: context.eventLoop)
      context.eventLoop.makeFutureWithTask {
        await IndexingWorkerHealthResponseBuilder.response(
          method: head.method,
          uri: head.uri,
          role: self.role,
          startupProbe: self.startupProbe,
          readinessProbe: self.readinessProbe
        )
      }.whenSuccess { response in
        loopBoundSelf.value.write(response, context: loopBoundContext.value)
      }
    }
  }

  func errorCaught(context: ChannelHandlerContext, error: Error) {
    context.close(promise: nil)
  }

  private func write(
    _ response: IndexingWorkerHealthResponseBuilder.Response,
    context: ChannelHandlerContext
  ) {
    var buffer = context.channel.allocator.buffer(capacity: response.body.utf8.count)
    buffer.writeString(response.body)
    var headers = HTTPHeaders()
    headers.add(name: "content-type", value: "application/json; charset=utf-8")
    headers.add(name: "content-length", value: String(buffer.readableBytes))
    headers.add(name: "connection", value: "close")
    context.write(
      wrapOutboundOut(.head(.init(version: .http1_1, status: response.status, headers: headers))),
      promise: nil
    )
    context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
    let loopBoundContext = context.loopBound
    context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in
      loopBoundContext.value.close(promise: nil)
    }
  }
}
