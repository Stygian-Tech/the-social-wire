public enum SportsReviewedNationalSides {
  public static var entities: [SportsEntity] {
    var result: [SportsEntity] = []
    for country in ["Australia", "England", "India", "New Zealand", "Pakistan", "South Africa", "Sri Lanka", "Bangladesh", "West Indies", "Afghanistan", "Ireland", "Scotland"] {
      for gender in ["Men's", "Women's"] {
        let key = country + ":" + gender + ":cricket"
        result.append(.init(id: SportsReviewedCatalog.id("national-side:" + key), name: country + " " + gender + " Cricket", kind: "national-side",
          sportID: SportsReviewedCatalog.id("sport:cricket"), aliases: [country + " " + gender.lowercased() + " cricket team"]))
      }
    }
    for country in ["Argentina", "Australia", "England", "France", "Ireland", "Italy", "Japan", "New Zealand", "Scotland", "South Africa", "Wales", "Fiji"] {
      for gender in ["Men's", "Women's"] {
        result.append(.init(id: SportsReviewedCatalog.id("national-side:" + country + ":" + gender + ":rugby-union"), name: country + " " + gender + " Rugby Union", kind: "national-side",
          sportID: SportsReviewedCatalog.id("sport:rugby-union"), aliases: [country + " " + gender.lowercased() + " rugby team"]))
      }
    }
    for country in ["Argentina", "Australia", "Brazil", "Canada", "China", "Colombia", "England", "France", "Germany", "Italy", "Japan", "Mexico", "Netherlands", "Nigeria", "Norway", "Portugal", "Scotland", "South Korea", "Spain", "Sweden", "United States"] {
      for gender in ["Men's", "Women's"] {
        result.append(.init(id: SportsReviewedCatalog.id("national-side:" + country + ":" + gender + ":football"), name: country + " " + gender + " Football", kind: "national-side",
          sportID: SportsReviewedCatalog.id("sport:football"), aliases: [country + " " + gender.lowercased() + " national football team"]))
      }
    }
    return result
  }
}
