import Foundation

public enum AtUriNormalization {
  public static func normalizeAtRepoParam(_ raw: String) -> String {
    raw.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
