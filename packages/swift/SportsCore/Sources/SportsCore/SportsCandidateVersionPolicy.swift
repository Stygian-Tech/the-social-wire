/// Cached eligibility and associations are valid only under the current resolver.
public enum SportsCandidateVersionPolicy {
  public static func isCurrent(_ candidates: [SportsRankCandidate]) -> Bool {
    candidates.allSatisfy { candidate in
      candidate.analysis.resolverVersion == SportsResolver.version
        && candidate.analysis.associations.allSatisfy { $0.resolverVersion == SportsResolver.version }
    }
  }
}
