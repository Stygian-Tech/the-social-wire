import Foundation

/// Gender belongs to the locally named competition/program, not every story entity.
enum SportsGenderContext {
  static func gender(_ value: String) -> String? {
    switch SportsResolver.normalize(value) {
    case "women", "womens", "female", "feminino", "feminina", "femenino", "femenina", "femminile", "frauen", "damen": return "women"
    case "men", "mens", "male", "masculino", "masculina", "maschile", "herren": return "men"
    default: return nil
    }
  }
  static func permits(alias: String, text: String, gender expected: String?) -> Bool {
    guard let expected else { return true }
    let phrase = SportsResolver.normalize(alias).split(separator: " ").map(String.init)
    let words = text.split(separator: " ").map(String.init)
    guard !phrase.isEmpty, words.count >= phrase.count else { return false }
    let boundaries = Set(["and", "or", "vs", "versus", "y", "e", "et", "und", "but", "while"])
    for start in 0...(words.count - phrase.count) where Array(words[start..<(start + phrase.count)]) == phrase {
      let end = start + phrase.count
      let embedded = phrase.compactMap(gender)
      if !embedded.isEmpty {
        if embedded.allSatisfy({ $0 == expected }) { return true }
        continue
      }
      var qualifiers: [(Int, String)] = []
      for direction in [-1, 1] {
        for distance in 1...2 {
          let offset = direction < 0 ? start - distance : end + distance - 1
          guard words.indices.contains(offset) else { break }
          if boundaries.contains(words[offset]) { break }
          if let value = gender(words[offset]) { qualifiers.append((distance, value)); break }
        }
      }
      guard let nearest = qualifiers.map({ $0.0 }).min() else { return true }
      if qualifiers.filter({ $0.0 == nearest }).allSatisfy({ $0.1 == expected }) { return true }
    }
    return false
  }
}
