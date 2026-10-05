import Testing

@testable import AppView

@Suite("Standard Reader cold list serving")
struct StandardReaderListEnrollmentTests {
  @Test("cold empty pages warm until enrollment finishes, while nonempty pages remain immediately available")
  func initialEnrollment() async {
    let state = StandardReaderListEnrollment()
    let gate = EnrollmentFixtureGate()
    let first = await state.begin(key: "list") { await gate.run() }
    #expect(!first)
    await gate.waitForStart()
    let duplicate = await state.begin(key: "list") { Issue.record("Duplicate enrollment ran") }
    #expect(!duplicate)
    #expect(StandardReaderListEnrollment.shouldWarm(empty: true, enrollmentComplete: first))
    #expect(!StandardReaderListEnrollment.shouldWarm(empty: false, enrollmentComplete: first))
    await gate.finish()
    await state.waitForCurrent(key: "list")
    let complete = await state.begin(key: "list") { Issue.record("Completed list enrolled twice") }
    #expect(complete)
    #expect(!StandardReaderListEnrollment.shouldWarm(empty: true, enrollmentComplete: complete))
  }

  @Test("a failed backfill does not become an authoritative empty feed")
  func failedEnrollment() async {
    let state = StandardReaderListEnrollment()
    _ = await state.begin(key: "list") { throw FixtureFailure() }
    await state.waitForCurrent(key: "list")
    let next = await state.begin(key: "list") { throw FixtureFailure() }
    #expect(!next)
    #expect(StandardReaderListEnrollment.shouldWarm(empty: true, enrollmentComplete: next))
    await state.waitForCurrent(key: "list")
  }

  private struct FixtureFailure: Error {}
}

private actor EnrollmentFixtureGate {
  private var started: CheckedContinuation<Void, Never>?
  private var release: CheckedContinuation<Void, Never>?
  private var running = false
  func run() async {
    running = true
    await withCheckedContinuation { continuation in
      release = continuation
      started?.resume()
      started = nil
    }
  }
  func waitForStart() async {
    if running { return }
    await withCheckedContinuation { started = $0 }
  }
  func finish() { release?.resume(); release = nil }
}
