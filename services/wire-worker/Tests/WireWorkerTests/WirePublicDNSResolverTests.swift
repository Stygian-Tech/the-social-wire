import Foundation
import Testing

@testable import WireWorkerCore

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

@Suite("Wire public DNS resolver")
struct WirePublicDNSResolverTests {
  @Test("rejects private and special-use addresses across IPv4 and IPv6")
  func publicAddressClassification() {
    let cases: [(String, Bool)] = [
      ("0.0.0.1", false), ("10.0.0.1", false), ("100.64.0.1", false),
      ("127.0.0.1", false), ("169.254.1.1", false), ("172.16.0.1", false),
      ("192.0.0.1", false), ("192.0.2.1", false), ("192.88.99.1", false),
      ("192.168.1.1", false), ("198.18.0.1", false), ("198.51.100.1", false),
      ("203.0.113.1", false), ("224.0.0.1", false), ("240.0.0.1", false),
      ("1.1.1.1", true), ("8.8.8.8", true),
      ("::", false), ("::1", false), ("64:ff9b::808:808", true),
      ("64:ff9b::a00:1", false), ("64:ff9b:1::1", false),
      ("100::1", false), ("2001::1", false), ("2001:1::1", true),
      ("2001:2::1", false), ("2001:3::1", true), ("2001:4:112::1", true),
      ("2001:5::1", false), ("2001:10::1", false), ("2001:20::1", true),
      ("2001:30::1", true), ("2001:db8::1", false), ("2002::1", false),
      ("3fff::1", false), ("5f00::1", false), ("fc00::1", false),
      ("fe80::1", false), ("ff00::1", false),
      ("2001:4860:4860::8888", true), ("2606:4700:4700::1111", true),
    ]
    for (address, expected) in cases {
      #expect(WirePublicDNSResolver.isPublicAddress(address) == expected)
    }
  }

  @Test("rejects an entire mixed public and private answer set")
  func rejectsMixedAnswerSet() async {
    let resolver = WirePublicDNSResolver(
      timeout: .seconds(1),
      resolver: { _ in ["1.1.1.1", "10.0.0.1"] }
    )
    await #expect(throws: WirePublicationQueryError.unsafeEndpoint) {
      try await resolver.validatePublicAddresses(for: "mixed.publisher.social")
    }
  }

  @Test("DNS timeout retains a bounded permit until the resolver exits")
  func boundedTimeoutAdmission() async throws {
    let admission = WireDNSResolverAdmission(maximumConcurrentResolutions: 1)
    let slow = WirePublicDNSResolver(
      timeout: .milliseconds(20),
      admission: admission,
      resolver: { _ in
        Thread.sleep(forTimeInterval: 0.15)
        return ["1.1.1.1"]
      }
    )
    await #expect(throws: WirePublicationQueryError.dnsUnavailable) {
      try await slow.validatePublicAddresses(for: "slow.publisher.social")
    }

    let blocked = WirePublicDNSResolver(
      timeout: .seconds(1),
      admission: admission,
      resolver: { _ in ["8.8.8.8"] }
    )
    await #expect(throws: WirePublicationQueryError.dnsUnavailable) {
      try await blocked.validatePublicAddresses(for: "blocked.publisher.social")
    }

    try await waitForAdmissionToDrain(admission)
    try await blocked.validatePublicAddresses(for: "recovered.publisher.social")
  }

  @Test("caller cancellation returns promptly without releasing a blocked permit")
  func boundedCancellationAdmission() async throws {
    let admission = WireDNSResolverAdmission(maximumConcurrentResolutions: 1)
    let resolver = WirePublicDNSResolver(
      timeout: .seconds(1),
      admission: admission,
      resolver: { _ in
        Thread.sleep(forTimeInterval: 0.15)
        return ["1.1.1.1"]
      }
    )
    let task = Task {
      try await resolver.validatePublicAddresses(for: "cancelled.publisher.social")
    }
    while await admission.activeCount() == 0 { await Task.yield() }
    task.cancel()
    await #expect(throws: CancellationError.self) {
      try await task.value
    }
    #expect(await admission.activeCount() == 1)
    try await waitForAdmissionToDrain(admission)
  }

  @Test("resolution failure is retryable and an empty answer is unsafe")
  func unavailableAndEmptyAnswers() async {
    let unavailable = WirePublicDNSResolver(
      timeout: .seconds(1), resolver: { _ in nil }
    )
    await #expect(throws: WirePublicationQueryError.dnsUnavailable) {
      try await unavailable.validatePublicAddresses(for: "missing.publisher.social")
    }

    let empty = WirePublicDNSResolver(
      timeout: .seconds(1), resolver: { _ in [] }
    )
    await #expect(throws: WirePublicationQueryError.unsafeEndpoint) {
      try await empty.validatePublicAddresses(for: "empty.publisher.social")
    }
  }

  private func waitForAdmissionToDrain(_ admission: WireDNSResolverAdmission) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(1))
    while await admission.activeCount() != 0, clock.now < deadline {
      try await Task.sleep(for: .milliseconds(5))
    }
    #expect(await admission.activeCount() == 0)
  }
}
