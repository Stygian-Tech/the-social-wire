public enum SportsNamedFeeds {
  public static let version = "sports-named-feeds-v2"
  public static func isSelectable(_ entity: SportsEntity) -> Bool {
    entity.active && ["sport", "competition", "classification", "team", "national-side", "ncaa-team", "athlete", "driver"].contains(entity.kind)
  }
  public static func catalog(entities: [SportsEntity]) -> [SportsFeedDefinition] {
    [.init(id: "sports", title: "Sports", kind: "global", description: "Global sports news, personalized to your interests.")]
      + entities.filter(isSelectable).sorted { $0.name < $1.name }.map {
        .init(id: "entity:" + $0.id, title: $0.name, kind: $0.kind, entityIDs: [$0.id], description: "Stories matching " + $0.name + ".", groupPath: $0.groupPath)
      }
  }
}
