public enum SportsSportHierarchy {
  public static func ancestors(of ids: Set<String>, catalog: [SportsEntity]) -> Set<String> {
    ancestors(of: ids, parents: parentIDs(catalog: catalog))
  }
  public static func parentIDs(catalog: [SportsEntity]) -> [String: Set<String>] {
    let sports = Set(catalog.filter { $0.kind == "sport" && $0.active }.map(\.id))
    var parents: [String: Set<String>] = Dictionary(catalog.compactMap { entity in
      guard sports.contains(entity.id), let parent = entity.sportID, sports.contains(parent) else { return nil }
      return (entity.id, Set([parent]))
    }, uniquingKeysWith: { $0.union($1) })
    // Ice hockey belongs to both Hockey and Winter Sports; keep its picker parent unchanged.
    // Official disciplines: https://support.olympics.com/hc/en-gb/articles/43002667811219
    let ice = SportsReviewedCatalog.id("sport:ice-hockey")
    let winter = SportsReviewedCatalog.id("sport:winter-sports")
    if sports.contains(ice), sports.contains(winter) { parents[ice, default: []].insert(winter) }
    return parents
  }
  public static func ancestors(of ids: Set<String>, parents: [String: Set<String>]) -> Set<String> {
    var result = ids
    var pending = Array(ids)
    while let id = pending.popLast() {
      for parent in parents[id] ?? [] {
        if result.insert(parent).inserted { pending.append(parent) }
      }
    }
    return result
  }
  public static func descendants(of ids: Set<String>, catalog: [SportsEntity]) -> Set<String> {
    let parents = parentIDs(catalog: catalog)
    var result = ids
    var changed = true
    while changed {
      changed = false
      for sport in catalog where sport.active && sport.kind == "sport" && !(parents[sport.id] ?? []).isDisjoint(with: result) {
        if result.insert(sport.id).inserted { changed = true }
      }
    }
    return result
  }
}
