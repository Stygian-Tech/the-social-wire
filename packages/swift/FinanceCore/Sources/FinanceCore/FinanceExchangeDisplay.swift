/// Reviewed provider-code labels. Unknown codes remain visible rather than inventing a venue.
/// Sources reviewed 2026-10-04:
/// https://data.bloomberglp.com/professional/sites/10/Bloomberg-Global-Equity-Indices-Methodology.pdf
/// https://www.openfigi.com/about/allocation-rules
/// https://assets.bwbx.io/documents/users/iqjWHBFdfxIU/rqdM03q29I1Y/v0
public enum FinanceExchangeDisplay {
  public static func name(for instrument: FinanceInstrument) -> String? {
    guard let code = instrument.exchange?.uppercased() else { return nil }
    // True composites are market-wide containers. Other codes can identify either a venue
    // or a composite; the FIGI relationship disambiguates them without merging listings.
    if let market = trueCompositeMarkets[code] { return market + " Composite" }
    if instrument.providerID == instrument.compositeFIGI, let market = compositeMarkets[code] {
      return market + " Composite"
    }
    return venues[code]
  }

  private static let trueCompositeMarkets = [
    "US": "United States", "JP": "Japan", "RO": "Romania", "GR": "Germany",
    "AU": "Australia", "CN": "Canada", "CH": "China", "IN": "India",
    "KS": "South Korea", "SM": "Spain", "SW": "Switzerland"
  ]

  private static let compositeMarkets = [
    "LN": "United Kingdom", "GY": "Germany", "HK": "Hong Kong", "FP": "France",
    "NA": "Netherlands", "BB": "Belgium", "DC": "Denmark", "FH": "Finland",
    "IM": "Italy", "SS": "Sweden", "NO": "Norway", "SP": "Singapore", "NZ": "New Zealand"
  ]

  private static let venues = [
    "UW": "Nasdaq Global Select Market", "UQ": "Nasdaq Global Market", "UR": "Nasdaq Capital Market",
    "UN": "New York Stock Exchange", "UA": "NYSE American", "UP": "NYSE Arca",
    "LN": "London Stock Exchange", "LI": "London Stock Exchange International",
    "JT": "Tokyo Stock Exchange", "GY": "Xetra", "HK": "Hong Kong Stock Exchange",
    "FP": "Euronext Paris", "NA": "Euronext Amsterdam", "BB": "Euronext Brussels",
    "ID": "Euronext Dublin", "NO": "Euronext Oslo", "PL": "Euronext Lisbon",
    "AT": "Australian Securities Exchange", "AV": "Vienna Stock Exchange", "CT": "Toronto Stock Exchange",
    "DC": "Nasdaq Copenhagen", "FH": "Nasdaq Helsinki", "SS": "Nasdaq Stockholm",
    "SF": "First North Stockholm", "IM": "Borsa Italiana", "IT": "Tel Aviv Stock Exchange",
    "SP": "Singapore Exchange", "NZ": "New Zealand Exchange", "SQ": "Spanish Stock Exchange",
    "SE": "SIX Swiss Exchange", "XW": "SIX Swiss Exchange"
  ]
}
