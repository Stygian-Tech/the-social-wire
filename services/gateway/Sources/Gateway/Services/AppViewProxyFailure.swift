import AsyncHTTPClient
import Hummingbird

/// Classifies transport failures without exposing URLs, credentials or raw errors.
enum AppViewProxyFailure: String {
  case timeout
  case cancelled
  case unavailable

  init(_ error: any Error) {
    if error is CancellationError {
      self = .cancelled
    } else if let clientError = error as? HTTPClientError {
      switch clientError {
      case .deadlineExceeded, .readTimeout, .writeTimeout, .connectTimeout,
        .getConnectionFromPoolTimeout, .tlsHandshakeTimeout, .httpProxyHandshakeTimeout,
        .socksHandshakeTimeout:
        self = .timeout
      case .cancelled, .requestStreamCancelled:
        self = .cancelled
      default:
        self = .unavailable
      }
    } else {
      self = .unavailable
    }
  }

  var responseError: any Error {
    switch self {
    case .timeout:
      HTTPError(.gatewayTimeout, message: "AppView exceeded its response deadline.")
    case .cancelled:
      CancellationError()
    case .unavailable:
      HTTPError(.badGateway, message: "AppView is temporarily unavailable.")
    }
  }
}
