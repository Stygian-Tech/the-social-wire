import Foundation
import GatewayCore
import Testing
import ThinAppViewCore

@testable import AppView

@Suite("Bootstrap first page without enrollment waits")
struct BootstrapEntriesPageSelectionTests {
  @Test("pending enrollment serves cache or unavailable without waiting", arguments: [false, true])
  func pendingEnrollment(hasCache: Bool) async throws {
    let (gate, release) = AsyncStream<Void>.makeStream()
    let enrollment = BootstrapEnrollment.start { for await _ in gate {} }
    // Release a regressed joining implementation so a failure cannot strand the suite.
    let watchdog = Task {
      do { try await Task.sleep(for: .seconds(5)) } catch { return }
      Issue.record("First-page selection waited for background enrollment")
      release.finish()
    }
    defer { watchdog.cancel(); release.finish() }
    let cachedAt = Date(timeIntervalSince1970: 1_800_000_000)
    let expiresAt = cachedAt.addingTimeInterval(300)
    let selection = try await BootstrapEntriesPageSelection.load(
      enrollment: enrollment,
      livePage: {
        Issue.record("An unfinished enrollment must not force a live first-page query")
        return nil
      },
      cachedPage: {
        hasCache ? AppViewProjectionCacheEntry(
          value: AppViewEntryListResponse(entries: [], cursor: "retained-page"),
          cachedAt: cachedAt, expiresAt: expiresAt
        ) : nil
      }
    )
    #expect(await enrollment.isFinished == false)
    #expect(selection.source == (hasCache ? .projectionCache : .unavailable))
    #expect(selection.page.cursor == (hasCache ? "retained-page" : nil))
    #expect(selection.cachedAt == (hasCache ? cachedAt : nil))
    #expect(selection.expiresAt == (hasCache ? expiresAt : nil))
  }

  @Test("completed enrollment prefers live data and falls back to cached evidence", arguments: [false, true])
  func completedEnrollment(hasLivePage: Bool) async throws {
    let enrollment = BootstrapEnrollment.start {}
    while !(await enrollment.isFinished) { await Task.yield() }
    let cachedAt = Date(timeIntervalSince1970: 1_800_000_000)
    let selection = try await BootstrapEntriesPageSelection.load(
      enrollment: enrollment,
      livePage: { hasLivePage ? AppViewEntryListResponse(entries: [], cursor: "live") : nil },
      cachedPage: {
        #expect(!hasLivePage)
        return AppViewProjectionCacheEntry(
          value: AppViewEntryListResponse(entries: [], cursor: "cache"),
          cachedAt: cachedAt, expiresAt: cachedAt.addingTimeInterval(300)
        )
      }
    )
    #expect(selection.source == (hasLivePage ? .liveProjection : .projectionCache))
    #expect(selection.page.cursor == (hasLivePage ? "live" : "cache"))
    #expect(selection.cachedAt == (hasLivePage ? nil : cachedAt))
  }

  @Test("cancelled selection exits without waiting for or cancelling background enrollment")
  func cancelledSelection() async {
    let (enrollmentGate, releaseEnrollment) = AsyncStream<Void>.makeStream()
    let enrollment = BootstrapEnrollment.start { for await _ in enrollmentGate {} }
    defer { releaseEnrollment.finish() }
    let (selectionGate, releaseSelection) = AsyncStream<Void>.makeStream()
    let selection = Task {
      for await _ in selectionGate {}
      return try await BootstrapEntriesPageSelection.load(
        enrollment: enrollment,
        livePage: { Issue.record("Cancelled selection queried live data"); return nil },
        cachedPage: { Issue.record("Cancelled selection queried cache"); return nil }
      )
    }
    selection.cancel()
    releaseSelection.finish()
    do {
      _ = try await selection.value
      Issue.record("Cancelled selection should throw")
    } catch is CancellationError {
      #expect(await enrollment.isFinished == false)
    } catch {
      Issue.record("Unexpected selection error: \(error)")
    }
  }
}
