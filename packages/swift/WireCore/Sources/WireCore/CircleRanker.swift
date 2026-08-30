import Foundation

public enum CircleRanker {
  public static func rank(
    candidates: [CircleRankCandidate],
    asOf: Date,
    config: CircleRankingConfig = CircleRankingConfig()
  ) throws -> CircleRankingResult {
    try config.validate()

    var ranked: [CircleRankedCandidate] = []
    var rejectedWithoutEligibleParticipants = 0
    var rejectedForInvalidInput = 0

    for candidate in candidates {
      guard valid(candidate) else {
        rejectedForInvalidInput += 1
        continue
      }
      let signals = eligibleSignals(candidate.participantSignals, asOf: asOf, config: config)
      let participants = participantSummaries(signals)
      guard !participants.isEmpty else {
        rejectedWithoutEligibleParticipants += 1
        continue
      }

      let breadth = clamp(
        log1p(Double(participants.count)) / log1p(Double(config.participantBreadthTarget))
      )
      let relationship = clamp(
        participants.values.reduce(0) { $0 + $1.relationshipWeight }
          / Double(participants.count)
      )
      let latestSignalAt = participants.values.map(\.latestSignalAt).max() ?? asOf
      let age = max(0, asOf.timeIntervalSince(latestSignalAt))
      let recency = pow(0.5, age / config.recencyHalfLife)
      let activeHour = participants.values.filter {
        asOf.timeIntervalSince($0.latestSignalAt) <= 60 * 60
      }.count
      let activeDay = participants.values.filter {
        asOf.timeIntervalSince($0.latestSignalAt) <= 24 * 60 * 60
      }.count
      let expectedHourly = max(1, Double(activeDay) / 24)
      let velocity = clamp(Double(activeHour) / (expectedHourly * 4))
      let recencyVelocity = clamp((recency + velocity) / 2)
      let qualityPresentation = clamp((candidate.quality + candidate.presentation) / 2)
      let interest = clamp(candidate.interestMatch)
      let components = CircleScoreComponents(
        participantBreadth: breadth,
        relationshipStrength: relationship,
        recencyVelocity: recencyVelocity,
        qualityPresentation: qualityPresentation,
        interestMatch: interest
      )
      let weights = config.weights
      let score =
        (components.participantBreadth * weights.participantBreadth)
        + (components.relationshipStrength * weights.relationshipStrength)
        + (components.recencyVelocity * weights.recencyVelocity)
        + (components.qualityPresentation * weights.qualityPresentation)
        + (components.interestMatch * weights.interestMatch)
      ranked.append(
        CircleRankedCandidate(candidate: candidate, score: score, components: components)
      )
    }

    ranked.sort {
      if $0.score != $1.score { return $0.score > $1.score }
      return $0.candidate.canonicalKey < $1.candidate.canonicalKey
    }
    return CircleRankingResult(
      items: ranked,
      diagnostics: CircleRankingDiagnostics(
        candidateCount: candidates.count,
        eligibleCount: ranked.count,
        rejectedWithoutEligibleParticipants: rejectedWithoutEligibleParticipants,
        rejectedForInvalidInput: rejectedForInvalidInput
      )
    )
  }

  private struct ParticipantSummary {
    var relationshipWeight: Double
    var latestSignalAt: Date
  }

  private static func participantSummaries(
    _ signals: [CircleParticipantSignal]
  ) -> [String: ParticipantSummary] {
    var participants: [String: ParticipantSummary] = [:]
    for signal in signals {
      let key = signal.participantKey.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !key.isEmpty else { continue }
      if let existing = participants[key] {
        participants[key] = ParticipantSummary(
          relationshipWeight: max(existing.relationshipWeight, signal.relationship.weight),
          latestSignalAt: max(existing.latestSignalAt, signal.occurredAt)
        )
      } else {
        participants[key] = ParticipantSummary(
          relationshipWeight: signal.relationship.weight,
          latestSignalAt: signal.occurredAt
        )
      }
    }
    return participants
  }

  private static func eligibleSignals(
    _ signals: [CircleParticipantSignal],
    asOf: Date,
    config: CircleRankingConfig
  ) -> [CircleParticipantSignal] {
    signals.filter { signal in
      let age = asOf.timeIntervalSince(signal.occurredAt)
      return age >= 0 && age <= config.maximumSignalAge
    }
  }

  private static func valid(_ candidate: CircleRankCandidate) -> Bool {
    let key = candidate.canonicalKey.trimmingCharacters(in: .whitespacesAndNewlines)
    return !key.isEmpty && key.utf8.count <= 160
      && candidate.quality.isFinite
      && candidate.presentation.isFinite
      && candidate.interestMatch.isFinite
  }

  private static func clamp(_ value: Double) -> Double {
    min(1, max(0, value))
  }
}
