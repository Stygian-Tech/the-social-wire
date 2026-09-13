import Foundation
import Logging
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import Testing
@testable import SocialWireRedis

@Suite("Redis blackholed sockets", .serialized)
struct RedisBlackholeTests {
  @Test
  func acceptedSocketWithoutRepliesTimesOutAndReconnects() async throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let accepted = NIOLockedValueBox(0)
    let received = NIOLockedValueBox(0)
    let closed = NIOLockedValueBox(0)
    let server = try await ServerBootstrap(group: group)
      .childChannelInitializer { channel in
        let ordinal = accepted.withLockedValue { count in
          count += 1
          return count
        }
        do {
          // Channel initializers execute on the channel's event loop. Keep this
          // stateful test peer there instead of transferring it as Sendable.
          try channel.pipeline.syncOperations.addHandler(BlackholeRedisPeer(
            blackhole: ordinal == 1, received: received, closed: closed))
          return channel.eventLoop.makeSucceededVoidFuture()
        } catch {
          return channel.eventLoop.makeFailedFuture(error)
        }
      }
      .bind(host: "127.0.0.1", port: 0).get()
    do {
      let port = try #require(server.localAddress?.port)
      let client = try RediStackRedisClient(
        configuration: RedisConfiguration(url: "redis://127.0.0.1:\(port)",
          maximumConnectionCount: 1, commandTimeoutMilliseconds: 100),
        logger: Logger(label: "redis.blackhole.test"))
      let startedAt = ContinuousClock.now
      do {
        try await client.ping()
        Issue.record("A connected Redis socket that never replies must time out")
      } catch {
        #expect(error is RedisCommandTimeoutError)
      }
      // The server's two-second rescue close bounds failures without making a
      // broken task-race timeout implementation pass this test.
      #expect(startedAt.duration(to: .now) < .seconds(1))
      #expect(received.withLockedValue { $0 } > 0)
      do {
        try await client.ping()
        #expect(accepted.withLockedValue { $0 } >= 2)
        #expect(closed.withLockedValue { $0 } >= 1)
      } catch {
        try? await client.shutdown()
        throw error
      }
      try await client.shutdown()
    } catch {
      try? await server.close().get()
      try? await group.shutdownGracefully()
      throw error
    }
    try await server.close().get()
    try await group.shutdownGracefully()
  }
}

private final class BlackholeRedisPeer: ChannelInboundHandler {
  typealias InboundIn = ByteBuffer
  typealias OutboundOut = ByteBuffer

  let blackhole: Bool
  let received: NIOLockedValueBox<Int>
  let closed: NIOLockedValueBox<Int>
  private var rescueClose: Scheduled<Void>?

  init(blackhole: Bool, received: NIOLockedValueBox<Int>, closed: NIOLockedValueBox<Int>) {
    self.blackhole = blackhole
    self.received = received
    self.closed = closed
  }

  func handlerAdded(context: ChannelHandlerContext) {
    let channel = context.channel
    rescueClose = context.eventLoop.scheduleTask(in: .seconds(2)) {
      channel.close(promise: nil)
    }
  }

  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    received.withLockedValue { $0 += unwrapInboundIn(data).readableBytes }
    guard !blackhole else { return }
    var reply = context.channel.allocator.buffer(capacity: 7)
    reply.writeString("+PONG\r\n")
    context.writeAndFlush(wrapOutboundOut(reply), promise: nil)
  }

  func channelInactive(context: ChannelHandlerContext) {
    rescueClose?.cancel()
    closed.withLockedValue { $0 += 1 }
    context.fireChannelInactive()
  }
}
