import Testing
@testable import IndexingWorkerCore

@Suite("Indexing worker configuration")
struct IndexingWorkerConfigTests {
  @Test("loads projection role with isolated component health ports")
  func projectionRole() throws {
    let config = try IndexingWorkerConfig.load([
      "INDEXING_WORKER_ROLE": "projection",
      "PORT": "9000",
      "RAILWAY_REPLICA_ID": "replica-a",
    ])

    #expect(config.role == .projection)
    #expect(config.port == 9000)
    #expect(config.appViewHealthPort == 9001)
    #expect(config.wireHealthPort == 9002)
    #expect(config.ownerID == "replica-a")
  }

  @Test("rejects absent role instead of silently combining all work")
  func requiresRole() {
    #expect(throws: IndexingWorkerConfigError.invalidRole("")) {
      try IndexingWorkerConfig.load([:])
    }
  }

  @Test("rejects duplicate ports and unsafe lease timing")
  func rejectsUnsafeCoordination() {
    #expect(throws: IndexingWorkerConfigError.duplicateHealthPort) {
      try IndexingWorkerConfig.load([
        "INDEXING_WORKER_ROLE": "coordinator",
        "PORT": "8080",
        "INDEXING_APPVIEW_HEALTH_PORT": "8080",
      ])
    }
    #expect(throws: IndexingWorkerConfigError.invalidLeaseTiming) {
      try IndexingWorkerConfig.load([
        "INDEXING_WORKER_ROLE": "coordinator",
        "INDEXING_ROLE_LEASE_SECONDS": "10",
        "INDEXING_ROLE_LEASE_RENEW_SECONDS": "10",
      ])
    }
    #expect(throws: IndexingWorkerConfigError.invalidPositiveInteger("INDEXING_WIRE_HEALTH_PORT")) {
      try IndexingWorkerConfig.load([
        "INDEXING_WORKER_ROLE": "projection",
        "PORT": "65534",
      ])
    }
  }
}
