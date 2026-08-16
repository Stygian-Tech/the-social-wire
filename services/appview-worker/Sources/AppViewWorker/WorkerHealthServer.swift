import Logging
import NIOCore
import NIOHTTP1
import NIOPosix

enum WorkerHealthServer {
  static func run(
    readinessProbe: @escaping @Sendable () async throws -> Void,
    host: String,
    port: Int,
    logger: Logger
  ) async throws {
    let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let bootstrap = ServerBootstrap(group: eventLoopGroup)
      .serverChannelOption(ChannelOptions.backlog, value: 128)
      .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
      .childChannelInitializer { channel in
        channel.pipeline.configureHTTPServerPipeline().flatMap {
          channel.pipeline.addHandler(
            WorkerHealthRequestHandler(readinessProbe: readinessProbe)
          )
        }
      }
      .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)

    let channel = try await bootstrap.bind(host: host, port: port).get()
    logger.info("Charybdis health server listening", metadata: ["host": "\(host)", "port": "\(port)"])

    try await withTaskCancellationHandler {
      try await channel.closeFuture.get()
    } onCancel: {
      channel.close(promise: nil)
    }
    try await eventLoopGroup.shutdownGracefully()
  }
}

enum WorkerHealthResponseBuilder {
  struct Response: Sendable {
    let status: HTTPResponseStatus
    let body: String
  }

  static func response(
    method: HTTPMethod,
    uri: String,
    readinessProbe: @escaping @Sendable () async throws -> Void
  ) async -> Response {
    guard method == .GET else {
      return Response(status: .methodNotAllowed, body: #"{"error":"method_not_allowed"}"#)
    }

    switch uri.split(separator: "?", maxSplits: 1).first.map(String.init) ?? uri {
    case "/health":
      return Response(status: .ok, body: #"{"service":"charybdis","status":"ok"}"#)
    case "/livez":
      return Response(status: .ok, body: #"{"service":"charybdis","status":"live"}"#)
    case "/readyz":
      do {
        try await readinessProbe()
        return Response(status: .ok, body: #"{"service":"charybdis","status":"ready"}"#)
      } catch {
        return Response(
          status: .serviceUnavailable,
          body: #"{"service":"charybdis","status":"unavailable"}"#
        )
      }
    default:
      return Response(status: .notFound, body: #"{"error":"not_found"}"#)
    }
  }
}

private final class WorkerHealthRequestHandler: ChannelInboundHandler, @unchecked Sendable {
  typealias InboundIn = HTTPServerRequestPart
  typealias OutboundOut = HTTPServerResponsePart

  private let readinessProbe: @Sendable () async throws -> Void
  private var requestHead: HTTPRequestHead?

  init(readinessProbe: @escaping @Sendable () async throws -> Void) {
    self.readinessProbe = readinessProbe
  }

  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    switch unwrapInboundIn(data) {
    case .head(let head):
      requestHead = head
    case .body:
      break
    case .end:
      guard let head = requestHead else {
        context.close(promise: nil)
        return
      }
      requestHead = nil
      let loopBoundContext = context.loopBound
      let loopBoundSelf = NIOLoopBound(self, eventLoop: context.eventLoop)
      context.eventLoop.makeFutureWithTask {
        await WorkerHealthResponseBuilder.response(
          method: head.method,
          uri: head.uri,
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
    _ response: WorkerHealthResponseBuilder.Response,
    context: ChannelHandlerContext
  ) {
    var buffer = context.channel.allocator.buffer(capacity: response.body.utf8.count)
    buffer.writeString(response.body)
    var headers = HTTPHeaders()
    headers.add(name: "content-type", value: "application/json; charset=utf-8")
    headers.add(name: "content-length", value: String(buffer.readableBytes))
    headers.add(name: "connection", value: "close")
    let head = HTTPResponseHead(version: .http1_1, status: response.status, headers: headers)
    context.write(wrapOutboundOut(.head(head)), promise: nil)
    context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
    let loopBoundContext = context.loopBound
    context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in
      loopBoundContext.value.close(promise: nil)
    }
  }
}
