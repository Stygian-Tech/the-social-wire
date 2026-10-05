import SportsCore

struct SportsProjectionCatalog: Sendable {
  let snapshot: SportsCatalogSnapshot
  var revision: String { snapshot.version }
}
