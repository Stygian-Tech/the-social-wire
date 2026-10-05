import Foundation

/// Explicit provider codes from https://www.thesportsdb.com/docs_api_data.php.
/// Unknown codes never imply that an event is active or complete from its clock or scores.
enum TheSportsDBEventStatus {
  static func normalize(_ value: String?) -> String {
    let value = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if value.contains("cancel") || value == "canc" { return "cancelled" }
    if value.contains("postpon") || ["pst", "post"].contains(value) { return "postponed" }
    if ["match finished", "ft", "aet", "aot", "ap", "pen", "finished"].contains(value) { return "finished" }
    if ["1h", "2h", "ht", "live", "in progress", "q1", "q2", "q3", "q4",
      "p1", "p2", "p3", "ot", "et", "p", "pt", "bt", "s1", "s2", "s3", "s4", "s5",
      "in1", "in2", "in3", "in4", "in5", "in6", "in7", "in8", "in9"].contains(value) { return "in-progress" }
    return "scheduled"
  }
}
