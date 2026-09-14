@preconcurrency import RediStack
import NIOCore

/// Retires an unresponsive socket so command futures and pool leases also finish.
/// Cancelling a task awaiting EventLoopFuture.get() does not cancel that future.
final class RedisCommandDeadlineHandler: ChannelOutboundHandler, Sendable {
  typealias OutboundIn = RedisCommand
  typealias OutboundOut = RedisCommand

  private let timeout: TimeAmount

  init(timeout: TimeAmount) {
    self.timeout = timeout
  }

  func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
    let command = unwrapOutboundIn(data)
    let channel = context.channel
    let deadline = context.eventLoop.scheduleTask(in: timeout) {
      // Start at the pipeline head: RedisCommandHandler must fail its entire FIFO
      // before the socket closes, preventing a late reply from reaching another caller.
      channel.pipeline.fireErrorCaught(RedisCommandTimeoutError())
    }
    command.responsePromise.futureResult.whenComplete { _ in deadline.cancel() }
    context.write(data, promise: promise)
  }
}
