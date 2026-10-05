public struct FinanceIndustry: Sendable {
  public let id: String
  public let title: String
  public let keywords: [String]
  public static let all: [Self] = [
    .init(id: "pharma", title: "Pharma", keywords: ["pharmaceutical", "pharmaceuticals", "pharma", "drugmaker", "drugmakers", "drug company", "drug companies", "drug prices", "drug pricing"]),
    .init(id: "biotech", title: "Biotech", keywords: ["biotech", "biotechnology"]),
    .init(id: "semiconductors", title: "Semiconductors", keywords: ["semiconductor", "semiconductors", "chipmakers", "chipmaker"]),
    .init(id: "software", title: "Software", keywords: ["software"]),
    .init(id: "banks", title: "Banks", keywords: ["bank", "banks", "banking"]),
    .init(id: "insurance", title: "Insurance", keywords: ["insurance", "insurer", "insurers"]),
    .init(id: "oil-gas", title: "Oil & Gas", keywords: ["crude oil", "natural gas", "petroleum", "oil company", "oil companies", "oil producer", "oil producers", "oil industry"] ),
    .init(id: "aerospace-defense", title: "Aerospace & Defense", keywords: ["aerospace", "defense contractor", "defence contractor"]),
    .init(id: "autos", title: "Autos", keywords: ["automotive", "automaker", "automakers", "auto industry"]),
    .init(id: "retail", title: "Retail", keywords: ["retail", "retailer", "retailers"]),
    .init(id: "telecom", title: "Telecom", keywords: ["telecom", "telecommunications"]),
    .init(id: "media", title: "Media & Entertainment", keywords: ["media company", "media companies", "entertainment industry", "streaming company", "streaming companies"]),
    .init(id: "hardware", title: "Hardware", keywords: ["computer hardware", "hardware company", "hardware industry"]),
    .init(id: "consumer-products", title: "Consumer Products", keywords: ["consumer products", "consumer goods"]),
    .init(id: "restaurants", title: "Restaurants", keywords: ["restaurant industry", "restaurant company", "restaurant companies", "restaurant chain"]),
    .init(id: "medical-devices", title: "Medical Devices", keywords: ["medical device", "medical devices"]),
    .init(id: "payments", title: "Payments", keywords: ["payment processor", "payments company", "payments industry"]),
    .init(id: "asset-management", title: "Asset Management", keywords: ["asset management", "asset manager", "asset managers"]),
    .init(id: "manufacturing", title: "Manufacturing", keywords: ["manufacturing", "manufacturer", "manufacturers"]),
    .init(id: "transportation", title: "Transportation", keywords: ["transportation industry", "shipping company", "shipping companies", "airline", "airlines"]),
    .init(id: "mining", title: "Mining & Metals", keywords: ["metals", "mineral mining", "mining company", "mining companies", "gold mining", "copper mining", "iron ore", "metal miners"])
  ]
}
