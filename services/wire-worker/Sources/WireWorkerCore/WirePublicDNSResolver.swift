import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

private actor WireDNSResolutionAttempt {
  private enum Outcome: Sendable {
    case resolved([String]?)
    case timedOut
    case cancelled
  }

  private let admission: WireDNSResolverAdmission
  private var outcome: Outcome?
  private var continuation: CheckedContinuation<[String]?, any Error>?

  init(admission: WireDNSResolverAdmission) { self.admission = admission }

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

  func timedOut() { finish(with: .timedOut) }

  func cancelled() { finish(with: .cancelled) }

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
    case .resolved(let addresses): continuation.resume(returning: addresses)
    case .timedOut: continuation.resume(throwing: WirePublicationQueryError.dnsUnavailable)
    case .cancelled: continuation.resume(throwing: CancellationError())
    }
  }
}

struct WirePublicDNSResolver: WireDNSResolving {
  typealias Resolver = @Sendable (String) -> [String]?

  private static let sharedAdmission = WireDNSResolverAdmission()
  private let timeout: Duration
  private let admission: WireDNSResolverAdmission
  private let resolver: Resolver

  init(
    timeout: Duration = .seconds(3),
    admission: WireDNSResolverAdmission = sharedAdmission,
    resolver: @escaping Resolver = resolveAddresses
  ) {
    self.timeout = timeout
    self.admission = admission
    self.resolver = resolver
  }

  func validatePublicAddresses(for host: String) async throws {
    try Task.checkCancellation()
    guard await admission.acquire() else { throw WirePublicationQueryError.dnsUnavailable }

    let attempt = WireDNSResolutionAttempt(admission: admission)
    Task.detached(priority: .utility) {
      let addresses = resolver(host)
      await attempt.resolverCompleted(addresses)
    }
    let timeoutTask = Task {
      do {
        try await Task.sleep(for: timeout)
        await attempt.timedOut()
      } catch {
        // The resolver completed first or the caller cancelled the timeout task.
      }
    }
    defer { timeoutTask.cancel() }

    let addresses = try await withTaskCancellationHandler {
      try await attempt.value()
    } onCancel: {
      Task { await attempt.cancelled() }
    }
    try Task.checkCancellation()
    guard let addresses else { throw WirePublicationQueryError.dnsUnavailable }
    guard !addresses.isEmpty, addresses.allSatisfy(Self.isPublicAddress) else {
      throw WirePublicationQueryError.unsafeEndpoint
    }
  }

  static func resolveAddresses(_ host: String) -> [String]? {
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

    var addresses: Set<String> = []
    var cursor: UnsafeMutablePointer<addrinfo>? = first
    while let current = cursor {
      defer { cursor = current.pointee.ai_next }
      guard let address = current.pointee.ai_addr else { continue }
      var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
      guard
        getnameinfo(
          address,
          current.pointee.ai_addrlen,
          &buffer,
          socklen_t(buffer.count),
          nil,
          0,
          NI_NUMERICHOST
        ) == 0
      else { return nil }
      let end = buffer.firstIndex(of: 0) ?? buffer.endIndex
      addresses.insert(
        String(decoding: buffer[..<end].map { UInt8(bitPattern: $0) }, as: UTF8.self))
    }
    return addresses.sorted()
  }

  static func isPublicAddress(_ address: String) -> Bool {
    var ipv4 = in_addr()
    if inet_pton(AF_INET, address, &ipv4) == 1 {
      return isPublicIPv4(withUnsafeBytes(of: ipv4) { Array($0) })
    }
    var ipv6 = in6_addr()
    if inet_pton(AF_INET6, address, &ipv6) == 1 {
      return isPublicIPv6(withUnsafeBytes(of: ipv6) { Array($0) })
    }
    return false
  }

  static func isPublicIPv4(_ bytes: [UInt8]) -> Bool {
    guard bytes.count == 4 else { return false }
    let a = bytes[0]
    let b = bytes[1]
    let c = bytes[2]
    if a == 0 || a == 10 || a == 127 || a >= 224 { return false }
    if a == 100 && (64...127).contains(b) { return false }
    if a == 169 && b == 254 { return false }
    if a == 172 && (16...31).contains(b) { return false }
    if a == 192 && b == 168 { return false }
    if a == 192 && b == 88 && c == 99 { return false }
    if a == 192 && b == 0 && (c == 0 || c == 2) { return false }
    if a == 198 && (b == 18 || b == 19) { return false }
    if a == 198 && b == 51 && c == 100 { return false }
    if a == 203 && b == 0 && c == 113 { return false }
    return true
  }

  static func isPublicIPv6(_ bytes: [UInt8]) -> Bool {
    guard bytes.count == 16 else { return false }
    if bytes[0..<12].elementsEqual([0, 0x64, 0xFF, 0x9B, 0, 0, 0, 0, 0, 0, 0, 0]) {
      return isPublicIPv4(Array(bytes.suffix(4)))
    }
    if bytes[0..<6].elementsEqual([0, 0x64, 0xFF, 0x9B, 0, 1]) { return false }
    if bytes[0..<8].elementsEqual([1, 0, 0, 0, 0, 0, 0, 1]) { return false }
    guard bytes[0] & 0xE0 == 0x20 else { return false }
    if bytes[0] == 0x20 && bytes[1] == 0x01, bytes[2] & 0xFE == 0 {
      if bytes[2] == 0 && bytes[3] == 1,
        bytes[4..<15].allSatisfy({ $0 == 0 }),
        [1, 2, 3].contains(bytes[15])
      {
        return true
      }
      if bytes[2] == 0 && bytes[3] == 3 { return true }
      if bytes[2...5].elementsEqual([0, 4, 1, 0x12]) { return true }
      if bytes[2] == 0 && [0x20, 0x30].contains(bytes[3] & 0xF0) { return true }
      return false
    }
    if bytes[0...3].elementsEqual([0x20, 0x01, 0x0D, 0xB8]) { return false }
    if bytes[0] == 0x20 && bytes[1] == 0x02 { return false }
    if bytes[0] == 0x3F && bytes[1] == 0xFF && bytes[2] & 0xF0 == 0 { return false }
    return true
  }
}
