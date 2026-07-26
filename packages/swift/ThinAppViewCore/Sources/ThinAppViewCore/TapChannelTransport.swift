import Foundation
import Logging

#if canImport(WebSocketKit)
import NIOCore
import NIOHTTP1
import NIOPosix
import WebSocketKit

enum TapChannelTransport {
  private static let maxFrameSize = 2 * 1_024 * 1_024
  private static let pingInterval = TimeAmount.seconds(15)
  private static let pongTimeout: TimeInterval = 35
  private static let watchdogPollInterval: TimeInterval = 5

  static func consume(
    channelURL: String,
    adminPassword: String,
    queueCapacity: Int,
    logger: Logger,
    onConnected: @Sendable @escaping () async -> Void = {},
    onHeartbeat: @Sendable @escaping () async -> Void = {},
    onQueueObservation: @Sendable @escaping (BoundedQueueObservation) async -> Void,
    handleMessage: @Sendable @escaping (
      String,
      @Sendable (Int64) async throws -> Void
    ) async throws -> Void
  ) async throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let socketBox = TapWebSocketBox()
    var headers = HTTPHeaders()
    headers.add(name: "Authorization", value: basicAuthorization(password: adminPassword))
    let clientConfiguration = WebSocketClient.Configuration(maxFrameSize: maxFrameSize)

    do {
      try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
          let resumed = TapContinuationGuard()
          WebSocket.connect(
            to: channelURL,
            headers: headers,
            configuration: clientConfiguration,
            on: group
          ) { socket in
            socketBox.set(socket)
            Task { await onConnected() }
            let pongDeadline = WebSocketPongDeadline(connectedAt: Date())
            socket.pingInterval = Self.pingInterval
            socket.onPong { _, _ in
              pongDeadline.recordPong(at: Date())
              Task { await onHeartbeat() }
            }
            let watchdog = Task {
              do {
                while !Task.isCancelled {
                  try await Task.sleep(for: .seconds(Self.watchdogPollInterval))
                  let expired = WebSocketPongWatchdog.expireIfNeeded(
                    deadline: pongDeadline,
                    at: Date(),
                    timeout: Self.pongTimeout
                  ) {
                    resumed.resumeOnce(
                      continuation,
                      with: .failure(WebSocketHeartbeatError.pongTimeout)
                    )
                    socketBox.close()
                  }
                  if expired { return }
                }
              } catch {
                return
              }
            }
            socketBox.setWatchdog(watchdog)
            let acknowledge: @Sendable (Int64) async throws -> Void = { eventId in
              try await socket.send(acknowledgementJSON(eventId: eventId))
            }
            let pump = BoundedSequentialMessagePump(
              capacity: queueCapacity,
              handleMessage: { text in
                try await TapMessageRetry.run {
                  try await handleMessage(text, acknowledge)
                }
              },
              onFailure: { error in
                resumed.resumeOnce(continuation, with: .failure(error))
                socketBox.close()
              },
              onObservation: { observation in
                Task { await onQueueObservation(observation) }
              }
            )
            logger.info("Tap acknowledgement channel connected")
            socket.onText { _, text in
              guard pump.enqueue(text) else {
                resumed.resumeOnce(
                  continuation,
                  with: .failure(TapChannelTransportError.queueOverflow)
                )
                socketBox.close()
                return
              }
            }
            socket.onClose.whenComplete { _ in
              socketBox.stopWatchdog()
              resumed.resumeOnce(
                continuation,
                with: .failure(TapChannelTransportError.connectionClosed)
              )
            }
          }.whenFailure { error in
            resumed.resumeOnce(continuation, with: .failure(error))
          }
        }
      } onCancel: {
        socketBox.close()
      }
    } catch {
      try await group.shutdownGracefully()
      throw error
    }
    try await group.shutdownGracefully()
  }

  private static func basicAuthorization(password: String) -> String {
    "Basic \(Data("admin:\(password)".utf8).base64EncodedString())"
  }

  private static func acknowledgementJSON(eventId: Int64) -> String {
    "{\"type\":\"ack\",\"id\":\(eventId)}"
  }
}

private final class TapWebSocketBox: @unchecked Sendable {
  private let lock = NSLock()
  private var socket: WebSocket?
  private var watchdog: Task<Void, Never>?

  func set(_ socket: WebSocket) {
    lock.lock()
    self.socket = socket
    lock.unlock()
  }

  func setWatchdog(_ watchdog: Task<Void, Never>) {
    lock.lock()
    let previous = self.watchdog
    self.watchdog = watchdog
    lock.unlock()
    previous?.cancel()
  }

  func stopWatchdog() {
    lock.lock()
    let watchdog = self.watchdog
    self.watchdog = nil
    lock.unlock()
    watchdog?.cancel()
  }

  func close() {
    lock.lock()
    let socket = socket
    let watchdog = self.watchdog
    self.watchdog = nil
    lock.unlock()
    watchdog?.cancel()
    _ = socket?.close()
  }
}

private final class TapContinuationGuard: @unchecked Sendable {
  private let lock = NSLock()
  private var resumed = false

  func resumeOnce(
    _ continuation: CheckedContinuation<Void, Error>,
    with result: Result<Void, Error>
  ) {
    lock.lock()
    defer { lock.unlock() }
    guard !resumed else { return }
    resumed = true
    continuation.resume(with: result)
  }
}

#else

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum TapChannelTransport {
  static func consume(
    channelURL: String,
    adminPassword: String,
    queueCapacity: Int,
    logger: Logger,
    onConnected: @Sendable @escaping () async -> Void = {},
    onHeartbeat: @Sendable @escaping () async -> Void = {},
    onQueueObservation: @Sendable @escaping (BoundedQueueObservation) async -> Void,
    handleMessage: @Sendable @escaping (
      String,
      @Sendable (Int64) async throws -> Void
    ) async throws -> Void
  ) async throws {
    guard let url = URL(string: channelURL) else {
      throw TapChannelTransportError.invalidURL
    }
    var request = URLRequest(url: url)
    let authorization = Data("admin:\(adminPassword)".utf8).base64EncodedString()
    request.setValue("Basic \(authorization)", forHTTPHeaderField: "Authorization")
    let task = URLSession.shared.webSocketTask(with: request)
    task.resume()
    defer { task.cancel(with: .goingAway, reason: nil) }
    try await WebSocketPingDeadline.wait { completion in
      task.sendPing(pongReceiveHandler: completion)
    }
    logger.info("Tap acknowledgement channel connected")
    await onConnected()
    await onQueueObservation(BoundedQueueObservation(depth: 0, capacity: 1, dropped: 0))

    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask {
        while !Task.isCancelled {
          let message = try await task.receive()
          let text: String?
          switch message {
          case .string(let value): text = value
          case .data(let data): text = String(data: data, encoding: .utf8)
          @unknown default: text = nil
          }
          guard let text else { continue }
          await onQueueObservation(BoundedQueueObservation(depth: 1, capacity: 1, dropped: 0))
          try await TapMessageRetry.run {
            try await handleMessage(text) { eventId in
              try await task.send(.string("{\"type\":\"ack\",\"id\":\(eventId)}"))
            }
          }
          await onQueueObservation(BoundedQueueObservation(depth: 0, capacity: 1, dropped: 0))
        }
      }
      group.addTask {
        while !Task.isCancelled {
          try await Task.sleep(for: .seconds(15))
          try await WebSocketPingDeadline.wait { completion in
            task.sendPing(pongReceiveHandler: completion)
          }
          await onHeartbeat()
        }
      }
      _ = try await group.next()
      group.cancelAll()
    }
    _ = queueCapacity
  }

}
#endif

enum TapChannelTransportError: Error {
  case invalidURL
  case queueOverflow
  case connectionClosed
}
