/// A reviewed sport-specific roster. Primary institutional membership is deliberately not inferred.
struct SportsReviewedCollegeConference {
  let key: String
  let name: String
  let division: String
  let sportKey: String
  let label: String
  let schools: [String]
  let source: String
  var competitionKey: String { "ncaa-conference:" + key + ":" + sportKey }
}
