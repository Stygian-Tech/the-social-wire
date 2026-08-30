import Foundation

enum WireDeclaredLanguageValidator {
  private static let latinEvidence: [String: Set<String>] = [
    "de": ["aber", "auf", "das", "der", "die", "ein", "eine", "fur", "ist", "mit", "nicht", "und", "von", "wie", "zu"],
    "en": ["and", "are", "as", "at", "by", "for", "from", "how", "in", "is", "new", "of", "on", "the", "this", "to", "what", "when", "why", "will", "with"],
    "es": ["como", "con", "de", "del", "el", "en", "es", "la", "las", "los", "para", "por", "que", "una", "y"],
    "fr": ["avec", "comment", "dans", "de", "des", "du", "en", "est", "francais", "la", "le", "les", "pour", "sur", "une"],
    "it": ["che", "come", "con", "da", "del", "della", "di", "e", "gli", "il", "in", "la", "le", "per", "una"],
    "nl": ["als", "de", "een", "en", "het", "hoe", "in", "is", "met", "op", "te", "van", "voor"],
    "pt": ["como", "com", "da", "de", "do", "dos", "em", "e", "nao", "o", "os", "para", "por", "que", "uma"],
    "tl": ["ang", "apektado", "habagat", "lugar", "malawakang", "mga", "na", "nagsagawa", "ng", "para", "sa", "ulat"],
    "tr": ["bir", "bu", "da", "de", "icin", "ile", "mi", "nasil", "ve"],
  ]

  static func validatedLanguageCode(
    declaredLanguageCode: String?,
    title: String?,
    summary: String?
  ) -> String? {
    guard let declared = normalized(declaredLanguageCode) else { return nil }
    let text = [title, summary].compactMap { $0 }.joined(separator: " ")
    guard text.unicodeScalars.filter({ $0.properties.isAlphabetic }).count >= 6 else {
      return nil
    }

    let scripts = scriptCounts(in: text)
    switch declared {
    case "ja":
      return scripts.japanese >= 2 || scripts.han >= 2 ? declared : nil
    case "zh":
      return scripts.han >= 2 && scripts.japanese == 0 ? declared : nil
    case "ko":
      return scripts.korean >= 2 ? declared : nil
    case "ru", "uk":
      return scripts.cyrillic >= 4 ? declared : nil
    case "ar", "fa":
      return scripts.arabic >= 4 ? declared : nil
    case "he":
      return scripts.hebrew >= 4 ? declared : nil
    case "hi":
      return scripts.devanagari >= 4 ? declared : nil
    case "bn":
      return scripts.bengali >= 4 ? declared : nil
    case "th":
      return scripts.thai >= 4 ? declared : nil
    default:
      break
    }

    guard let declaredWords = latinEvidence[declared], scripts.nonLatin == 0 else { return nil }
    let tokens = Set(
      text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        .lowercased()
        .components(separatedBy: CharacterSet.letters.inverted)
        .filter { !$0.isEmpty }
    )
    let declaredScore = tokens.intersection(declaredWords).count
    guard declaredScore >= 2 else { return nil }
    let strongestContradiction = latinEvidence
      .filter { $0.key != declared }
      .map { tokens.intersection($0.value).count }
      .max() ?? 0
    return strongestContradiction > declaredScore ? nil : declared
  }

  private static func normalized(_ raw: String?) -> String? {
    guard let raw else { return nil }
    let code = raw.replacingOccurrences(of: "_", with: "-")
      .split(separator: "-", maxSplits: 1)
      .first.map(String.init)?.lowercased()
    guard let code, code.range(of: #"^[a-z]{2,3}$"#, options: .regularExpression) != nil else {
      return nil
    }
    return code
  }

  private static func scriptCounts(in text: String) -> (
    japanese: Int, han: Int, korean: Int, cyrillic: Int, arabic: Int,
    hebrew: Int, devanagari: Int, bengali: Int, thai: Int, nonLatin: Int
  ) {
    var japanese = 0
    var han = 0
    var korean = 0
    var cyrillic = 0
    var arabic = 0
    var hebrew = 0
    var devanagari = 0
    var bengali = 0
    var thai = 0
    for scalar in text.unicodeScalars where scalar.properties.isAlphabetic {
      switch scalar.value {
      case 0x3040...0x30FF: japanese += 1
      case 0x3400...0x9FFF: han += 1
      case 0xAC00...0xD7AF: korean += 1
      case 0x0400...0x052F: cyrillic += 1
      case 0x0600...0x06FF, 0x0750...0x077F, 0x08A0...0x08FF: arabic += 1
      case 0x0590...0x05FF: hebrew += 1
      case 0x0900...0x097F: devanagari += 1
      case 0x0980...0x09FF: bengali += 1
      case 0x0E00...0x0E7F: thai += 1
      default: break
      }
    }
    return (
      japanese, han, korean, cyrillic, arabic, hebrew, devanagari, bengali, thai,
      japanese + han + korean + cyrillic + arabic + hebrew + devanagari + bengali + thai
    )
  }
}
