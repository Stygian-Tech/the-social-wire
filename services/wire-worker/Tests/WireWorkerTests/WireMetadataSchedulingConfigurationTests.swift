import Testing

@testable import WireWorkerCore

struct WireMetadataSchedulingConfigurationTests {
  @Test("scheduling trial flags default off and repair pacing is bounded")
  func defaultsAndBounds() {
    let defaults = WireMetadataSchedulingConfiguration.load([:])
    #expect(!defaults.readerEnabled && !defaults.maintenanceEnabled)
    #expect(defaults.repairIntervalMilliseconds == 2_000)
    #expect(WireMetadataSchedulingConfiguration.load(["WIRE_METADATA_REPAIR_INTERVAL_MS": "-10"])
      .repairIntervalMilliseconds == 250)
    #expect(WireMetadataSchedulingConfiguration.load(["WIRE_METADATA_REPAIR_INTERVAL_MS": "999999"])
      .repairIntervalMilliseconds == 60_000)
    let trial = WireMetadataSchedulingConfiguration.load([
      "WIRE_METADATA_SCHEDULING_READ_ENABLED": "true",
      "WIRE_METADATA_SCHEDULING_MAINTENANCE_ENABLED": "1",
    ])
    #expect(trial.readerEnabled && trial.maintenanceEnabled)
  }
}
