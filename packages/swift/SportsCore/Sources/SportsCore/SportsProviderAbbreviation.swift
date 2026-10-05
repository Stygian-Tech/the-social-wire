import Foundation

/// Only the provider's explicit short-code attribute qualifies; names and aliases never do.
public enum SportsProviderAbbreviation {
  public static func validated(_ value: String?, providerTeamID: String?) -> String? {
    guard let providerTeamID, !providerTeamID.isEmpty,
      providerTeamID.utf8.allSatisfy({ (48...57).contains($0) }), let value else { return nil }
    let code = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    guard (2...8).contains(code.utf8.count),
      code.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) }) else { return nil }
    return code
  }
}
