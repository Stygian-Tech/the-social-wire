public enum SportsReviewedPeople {
  /// Identity-only CC0 Wikidata references reviewed 2026-10-03; no current team or image rights inferred.
  public static var entities: [SportsEntity] {
    [
      ("lewis-hamilton", "Lewis Hamilton", "driver", "motorsport", "Q9673"),
      ("max-verstappen", "Max Verstappen", "driver", "motorsport", "Q2239218"),
      ("aja-wilson", "A'ja Wilson", "athlete", "basketball", "Q21623331"),
      ("serena-williams", "Serena Williams", "athlete", "tennis", "Q11459"),
      ("lionel-messi", "Lionel Messi", "athlete", "football", "Q615"),
      ("lebron-james", "LeBron James", "athlete", "basketball", "Q36159"),
      ("virat-kohli", "Virat Kohli", "athlete", "cricket", "Q213854")
    ].map { key, name, kind, sport, reference in
      SportsEntity(id: SportsReviewedCatalog.id("person:" + key), name: name, kind: kind,
        sportID: SportsReviewedCatalog.id("sport:" + sport), providerIDs: ["wikidata": reference])
    }
  }
}
