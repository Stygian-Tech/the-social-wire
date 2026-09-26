import Testing

@Suite("Postgres test schema preparation")
struct PostgresTestSchemaPreparationTests {
  @Test("concurrent fixtures install each database once before using its schema")
  func concurrentPreparation() async throws {
    let preparation = PostgresTestSchemaPreparation()
    let calls = Counter()
    try await withThrowingTaskGroup(of: Void.self) { group in
      for _ in 0..<50 {
        group.addTask {
          try await preparation.prepare(database: "first") {
            await calls.increment()
            await Task.yield()
          }
          #expect(await calls.value == 1)
        }
      }
      try await group.waitForAll()
    }
    try await preparation.prepare(database: "second") { await calls.increment() }
    #expect(await calls.value == 2)
  }

  @Test("failed setup remains failed instead of racing another DDL installation")
  func failedPreparation() async {
    let preparation = PostgresTestSchemaPreparation()
    let calls = Counter()
    await withTaskGroup(of: Void.self) { group in
      for _ in 0..<50 {
        group.addTask {
          do {
            try await preparation.prepare(database: "failed") {
              await calls.increment()
              await Task.yield()
              throw SetupFailure.failed
            }
            Issue.record("Fixture must not use a partially installed schema")
          } catch {
            #expect(error is SetupFailure)
          }
        }
      }
    }
    #expect(await calls.value == 1)
  }

  private enum SetupFailure: Error { case failed }

  private actor Counter {
    var value = 0
    func increment() { value += 1 }
  }
}
