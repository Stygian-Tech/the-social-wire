#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

actor PublicDNSResolverAdmission {
  private let maximumConcurrentResolutions: Int
  private var activeResolutions = 0

  init(maximumConcurrentResolutions: Int = 8) {
    self.maximumConcurrentResolutions = max(maximumConcurrentResolutions, 1)
  }

  func acquire() -> Bool {
    guard activeResolutions < maximumConcurrentResolutions else { return false }
    activeResolutions += 1
    return true
  }

  func release() {
    precondition(activeResolutions > 0)
    activeResolutions -= 1
  }

  func activeCount() -> Int {
    activeResolutions
  }
}

private actor PublicDNSResolutionAttempt {
  private enum Outcome: Sendable {
    case resolved([String]?)
    case unavailable
  }

  private let admission: PublicDNSResolverAdmission
  private var outcome: Outcome?
  private var continuation: CheckedContinuation<[String]?, any Error>?

  init(admission: PublicDNSResolverAdmission) {
    self.admission = admission
  }

  func value() async throws -> [String]? {
    try await withCheckedThrowingContinuation { continuation in
      if let outcome {
        Self.resume(continuation, with: outcome)
      } else {
        self.continuation = continuation
      }
    }
  }

  func resolverCompleted(_ addresses: [String]?) async {
    await admission.release()
    finish(with: .resolved(addresses))
  }

  func callerTimedOutOrCancelled() {
    finish(with: .unavailable)
  }

  private func finish(with newOutcome: Outcome) {
    guard outcome == nil else { return }
    outcome = newOutcome
    guard let continuation else { return }
    self.continuation = nil
    Self.resume(continuation, with: newOutcome)
  }

  private static func resume(
    _ continuation: CheckedContinuation<[String]?, any Error>,
    with outcome: Outcome
  ) {
    switch outcome {
    case .resolved(let addresses):
      continuation.resume(returning: addresses)
    case .unavailable:
      continuation.resume(throwing: PDSAccessTokenAttestationError.unavailable)
    }
  }
}

/// Resolves an untrusted HTTPS endpoint immediately before use and rejects it unless every
/// returned address is globally routable. This complements hostname checks by blocking DNS
/// answers that point at loopback, link-local, private, documentation, or multicast networks.
enum PublicDNSAddressValidator {
  typealias Resolver = @Sendable (String) -> [String]?

  private static let sharedAdmission = PublicDNSResolverAdmission()

  static func validatedAddress(
    for baseURL: String,
    deadline: ContinuousClock.Instant = .now.advanced(by: .seconds(10)),
    admission: PublicDNSResolverAdmission = sharedAdmission,
    resolver: @escaping Resolver = resolvePublicAddresses
  ) async throws -> String {
    guard let components = URLComponents(string: baseURL),
      components.scheme?.lowercased() == "https",
      let host = components.host,
      !host.isEmpty
    else {
      throw PDSAccessTokenAttestationError.invalid
    }

    try Task.checkCancellation()
    guard await admission.acquire() else {
      throw PDSAccessTokenAttestationError.unavailable
    }

    let attempt = PublicDNSResolutionAttempt(admission: admission)
    Task.detached(priority: .utility) {
      let addresses = resolver(host)
      await attempt.resolverCompleted(addresses)
    }
    let timeoutTask = Task {
      do {
        try await Task.sleep(until: deadline, clock: .continuous)
        await attempt.callerTimedOutOrCancelled()
      } catch {
        // Cancellation means the resolver completed first and the deadline is no longer needed.
      }
    }
    defer { timeoutTask.cancel() }

    let addresses = try await withTaskCancellationHandler {
      try await attempt.value()
    } onCancel: {
      Task { await attempt.callerTimedOutOrCancelled() }
    }
    guard let addresses else { throw PDSAccessTokenAttestationError.unavailable }
    guard let address = addresses.first else { throw PDSAccessTokenAttestationError.invalid }
    return address
  }

  /// `nil` means DNS resolution failed; `false` means no exclusively public answer set exists.
  static func resolveOnlyPublicAddresses(host: String) -> Bool? {
    resolvePublicAddresses(host: host).map { !$0.isEmpty }
  }

  /// A nonempty result contains only globally routable numeric addresses. If even one DNS answer
  /// is private/special-use, the entire endpoint is rejected instead of picking a convenient one.
  static func resolvePublicAddresses(host: String) -> [String]? {
    var hints = addrinfo()
    hints.ai_family = AF_UNSPEC
#if canImport(Darwin)
    hints.ai_socktype = SOCK_STREAM
#else
    hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
#endif
    var result: UnsafeMutablePointer<addrinfo>?
    guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else { return nil }
    defer { freeaddrinfo(first) }

    var addresses: [String] = []
    var cursor: UnsafeMutablePointer<addrinfo>? = first
    while let current = cursor {
      defer { cursor = current.pointee.ai_next }
      guard let address = current.pointee.ai_addr else { continue }
      switch Int32(current.pointee.ai_family) {
      case AF_INET:
        let socketAddress = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in.self)
        let bytes = withUnsafeBytes(of: socketAddress.pointee.sin_addr) { Array($0) }
        guard isPublicIPv4(bytes) else { return [] }
      case AF_INET6:
        let socketAddress = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in6.self)
        let bytes = withUnsafeBytes(of: socketAddress.pointee.sin6_addr) { Array($0) }
        guard isPublicIPv6(bytes) else { return [] }
      default:
        continue
      }
      var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
      guard getnameinfo(
        address,
        current.pointee.ai_addrlen,
        &buffer,
        socklen_t(buffer.count),
        nil,
        0,
        NI_NUMERICHOST
      ) == 0 else { return nil }
      let end = buffer.firstIndex(of: 0) ?? buffer.endIndex
      addresses.append(
        String(decoding: buffer[..<end].map { UInt8(bitPattern: $0) }, as: UTF8.self)
      )
    }
    return Array(Set(addresses)).sorted()
  }

  static func isPublicIPv4(_ bytes: [UInt8]) -> Bool {
    guard bytes.count == 4 else { return false }
    let a = bytes[0], b = bytes[1], c = bytes[2]
    if a == 0 || a == 10 || a == 127 || a >= 224 { return false }
    if a == 100 && (64...127).contains(b) { return false }
    if a == 169 && b == 254 { return false }
    if a == 172 && (16...31).contains(b) { return false }
    if a == 192 && b == 168 { return false }
    if a == 192 && b == 88 && c == 99 { return false }
    if a == 198 && (b == 18 || b == 19) { return false }
    if a == 192 && b == 0 && (c == 0 || c == 2) { return false }
    if a == 198 && b == 51 && c == 100 { return false }
    if a == 203 && b == 0 && c == 113 { return false }
    return true
  }

  static func isPublicIPv6(_ bytes: [UInt8]) -> Bool {
    guard bytes.count == 16 else { return false }
    if bytes[0..<12].elementsEqual([0, 0x64, 0xFF, 0x9B, 0, 0, 0, 0, 0, 0, 0, 0]) {
      // IANA marks the well-known translation prefix globally reachable, but a translator could
      // otherwise turn an embedded private IPv4 address into an SSRF route.
      return isPublicIPv4(Array(bytes.suffix(4)))
    }
    if bytes[0..<6].elementsEqual([0, 0x64, 0xFF, 0x9B, 0, 1]) { return false }
    if bytes[0..<8].elementsEqual([1, 0, 0, 0, 0, 0, 0, 1]) { return false }

    // IANA currently allocates ordinary globally routable unicast space from 2000::/3. Reject all
    // transition, local, multicast, and unallocated prefixes outside that block fail closed.
    guard bytes[0] & 0xE0 == 0x20 else { return false }
    if bytes[0] == 0x20 && bytes[1] == 0x01, bytes[2] & 0xFE == 0 {
      // 2001::/23 is non-global by default. Preserve only its IANA entries explicitly marked
      // globally reachable; TEREDO/benchmarking/deprecated space and unassigned holes fail closed.
      if bytes[2] == 0 && bytes[3] == 1,
        bytes[4..<15].allSatisfy({ $0 == 0 }),
        [1, 2, 3].contains(bytes[15])
      {
        return true
      }
      if bytes[2] == 0 && bytes[3] == 3 { return true }  // AMT 2001:3::/32.
      if bytes[2...5].elementsEqual([0, 4, 1, 0x12]) { return true }  // AS112-v6.
      if bytes[2] == 0 && [0x20, 0x30].contains(bytes[3] & 0xF0) { return true }
      return false
    }
    if bytes[0...3].elementsEqual([0x20, 0x01, 0x0D, 0xB8]) { return false }
    if bytes[0] == 0x20 && bytes[1] == 0x02 { return false }  // Deprecated 6to4 2002::/16.
    if bytes[0] == 0x3F && bytes[1] == 0xFF && bytes[2] & 0xF0 == 0 {
      return false  // Documentation 3fff::/20.
    }
    return true
  }
}
