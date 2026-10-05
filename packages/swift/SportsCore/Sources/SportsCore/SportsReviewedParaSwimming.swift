/// Reviewed competition classes; SM is a medley entry index, kept distinct from S/SB.
enum SportsReviewedParaSwimming {
  static let reviewSource = "https://www.paralympic.org/swimming/classification"
  static let codes = (1...14).map { "S\($0)" }
    + ((1...9).map { "SB\($0)" } + (11...14).map { "SB\($0)" })
    + (1...14).map { "SM\($0)" }
  static var entities: [SportsEntity] {
    let swimming = SportsReviewedCatalog.id("sport:swimming")
    let umbrella = SportsReviewedCatalog.id("competition:para-swimming")
    return [.init(id: umbrella, name: "Para Swimming", kind: "competition", sportID: swimming,
      aliases: ["paraswimming"], groupPath: ["Competitions", "Swimming", "Para Swimming"])]
      + codes.map { code in
        let stroke = code.hasPrefix("SM") ? "SM · Individual Medley" : code.hasPrefix("SB") ? "SB · Breaststroke" : "S · Freestyle, Backstroke and Butterfly"
        return .init(id: SportsReviewedCatalog.id("classification:para-swimming-" + code.lowercased()),
          name: "Para Swimming \(code)", kind: "classification", sportID: swimming, competitionIDs: [umbrella],
          aliases: [code], groupPath: ["Swimming", "Para Swimming", "Classes and Medley Indices", stroke])
      }
  }
  private static let codeByID = Dictionary(uniqueKeysWithValues: codes.map {
    (SportsReviewedCatalog.id("classification:para-swimming-" + $0.lowercased()), $0)
  })
  static func classCode(for id: String) -> String? { codeByID[id] }
}
