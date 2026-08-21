import Logging
import NIOCore
import NIOHTTP1
import NIOPosix

enum WireHealthServer {
  static func run(
    databaseProbe: @escaping @Sendable () async throws -> Void,
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
            WireHealthRequestHandler(
              databaseProbe: databaseProbe,
              readinessProbe: readinessProbe
            )
          )
        }
      }
      .bind(host: host, port: port)
      .get()
    logger.info("The Wire worker health server listening", metadata: ["port": .string(String(port))])
    try await withTaskCancellationHandler {
      try await channel.closeFuture.get()
    } onCancel: {
      channel.close(promise: nil)
    }
    try await group.shutdownGracefully()
  }
}

private final class WireHealthRequestHandler: ChannelInboundHandler, @unchecked Sendable {
  typealias InboundIn = HTTPServerRequestPart
  typealias OutboundOut = HTTPServerResponsePart

  private let databaseProbe: @Sendable () async throws -> Void
  private let readinessProbe: @Sendable () async throws -> Void
  private var requestHead: HTTPRequestHead?

  init(
    databaseProbe: @escaping @Sendable () async throws -> Void,
    readinessProbe: @escaping @Sendable () async throws -> Void
  ) {
    self.databaseProbe = databaseProbe
    self.readinessProbe = readinessProbe
  }

  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    switch unwrapInboundIn(data) {
    case .head(let head): requestHead = head
    case .body: break
    case .end:
      guard let head = requestHead else { context.close(promise: nil); return }
      requestHead = nil
      let loopBoundContext = context.loopBound
      let loopBoundSelf = NIOLoopBound(self, eventLoop: context.eventLoop)
      context.eventLoop.makeFutureWithTask {
        await WireHealthResponseBuilder.response(
          method: head.method,
          uri: head.uri,
          databaseProbe: self.databaseProbe,
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

  private func write(_ response: WireHealthResponseBuilder.Response, context: ChannelHandlerContext) {
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
