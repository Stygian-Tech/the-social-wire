struct WireMetadataSchedulingConfiguration: Sendable {
  var readerEnabled = false
  var maintenanceEnabled = false
  var repairIntervalMilliseconds = 2_000

  static func load(_ environment: [String: String]) -> Self {
    func enabled(_ key: String) -> Bool {
      ["true", "1"].contains(environment[key]?.lowercased() ?? "false")
    }
    return Self(
      readerEnabled: enabled("WIRE_METADATA_SCHEDULING_READ_ENABLED"),
      maintenanceEnabled: enabled("WIRE_METADATA_SCHEDULING_MAINTENANCE_ENABLED"),
      repairIntervalMilliseconds: max(250, min(60_000,
        Int(environment["WIRE_METADATA_REPAIR_INTERVAL_MS"] ?? "") ?? 2_000)))
  }
}
