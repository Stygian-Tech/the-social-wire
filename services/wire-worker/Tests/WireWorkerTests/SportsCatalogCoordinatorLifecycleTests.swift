import Testing
@testable import WireWorkerCore

struct SportsCatalogCoordinatorLifecycleTests {
  @Test func reviewedRefreshCompletesBeforeFailingWireGeneration() async {
    let evidence = SportsCatalogLifecycleEvidence()
    await #expect(throws: SportsCatalogLifecycleFailure.wire) {
      let _: Int = try await WireWorkerRuntime.runGenerationWithSportsCatalog(
        refreshCatalog: { await evidence.record("catalog") },
        generateWire: { await evidence.record("wire"); throw SportsCatalogLifecycleFailure.wire },
        onCatalogFailure: { _ in await evidence.record("catalog-failure") })
    }
    #expect(await evidence.events == ["catalog", "wire"])
  }

  @Test func optionalRefreshFailureDoesNotSkipOrChangeWireFailure() async {
    let evidence = SportsCatalogLifecycleEvidence()
    await #expect(throws: SportsCatalogLifecycleFailure.wire) {
      let _: Int = try await WireWorkerRuntime.runGenerationWithSportsCatalog(
        refreshCatalog: { throw SportsCatalogLifecycleFailure.catalog },
        generateWire: { await evidence.record("wire"); throw SportsCatalogLifecycleFailure.wire },
        onCatalogFailure: { _ in await evidence.record("catalog-failure") })
    }
    #expect(await evidence.events == ["catalog-failure", "wire"])
  }

  @Test func cancelledRefreshNeverStartsWireGeneration() async {
    let evidence = SportsCatalogLifecycleEvidence()
    await #expect(throws: CancellationError.self) {
      let _: Int = try await WireWorkerRuntime.runGenerationWithSportsCatalog(
        refreshCatalog: { throw CancellationError() },
        generateWire: { await evidence.record("wire"); return 1 },
        onCatalogFailure: { _ in await evidence.record("catalog-failure") })
    }
    #expect(await evidence.events.isEmpty)
  }
}

private enum SportsCatalogLifecycleFailure: Error { case catalog, wire }
private actor SportsCatalogLifecycleEvidence {
  var events: [String] = []
  func record(_ event: String) { events.append(event) }
}
