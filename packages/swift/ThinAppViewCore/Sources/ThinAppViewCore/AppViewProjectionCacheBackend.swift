public enum AppViewProjectionCacheBackend: String, Sendable {
  case sqlite
  case postgres
  case redis

  public static func fromEnvironment(
    _ environment: [String: String],
    default fallback: AppViewProjectionCacheBackend
  ) throws -> AppViewProjectionCacheBackend {
    guard let raw = environment["APPVIEW_CACHE_BACKEND"]?.lowercased(), !raw.isEmpty else {
      return fallback
    }
    guard let backend = AppViewProjectionCacheBackend(rawValue: raw) else {
      throw AppViewProjectionCacheBackendError.unsupported(raw)
    }
    return backend
  }
}

public enum AppViewProjectionCacheBackendError: Error, Sendable, Equatable {
  case unsupported(String)
}
