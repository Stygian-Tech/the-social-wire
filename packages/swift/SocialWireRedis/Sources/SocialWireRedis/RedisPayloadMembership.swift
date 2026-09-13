import Foundation

/// Exact multiset comparison retains duplicates (for example a story in two modules).
public enum RedisPayloadMembership {
  public static func matches(_ loaded: [[String]], expected: [[String]]) -> Bool {
    loaded.sorted { $0.lexicographicallyPrecedes($1) }
      == expected.sorted { $0.lexicographicallyPrecedes($1) }
  }

  public static func fields(in revision: String, indices: [Int]) -> [[String]]? {
    var result: [[String]] = []
    for token in revision.split(separator: "\n") {
      guard let fields = try? JSONSerialization.jsonObject(with: Data(token.utf8)) as? [Any]
      else { return nil }
      var selected: [String] = []
      for index in indices {
        guard fields.indices.contains(index), let value = fields[index] as? String else { return nil }
        selected.append(value)
      }
      result.append(selected)
    }
    return result
  }
}
