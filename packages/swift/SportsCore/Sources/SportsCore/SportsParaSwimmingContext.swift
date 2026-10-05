enum SportsParaSwimmingContext {
  static func permits(_ text: String) -> Bool {
    SportsSwimmingContext.isCompetitive(text)
      && ["para swimming", "paraswimming", "paralympic", "paralympics", "paralympic games"].contains {
        SportsResolver.contains($0, in: text)
      }
  }
  static func containsClass(_ code: String, in text: String) -> Bool {
    permits(text) && SportsResolver.contains(code, in: text)
  }
}
