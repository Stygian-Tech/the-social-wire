public enum WireDiversityReranker {
  public static func rerank(
    _ ranked: [WireScoredCandidate],
    policy: WireDiversityPolicy
  ) -> WireDiversityResult {
    guard !ranked.isEmpty else { return WireDiversityResult(items: [], interventions: []) }

    let pageSize = min(policy.firstPageLimit, ranked.count)
    var caps = Caps(policy: policy)
    var pass = select(ranked, pageSize: pageSize, caps: caps)
    var interventions = pass.interventions
    let strictTarget = min(pageSize, policy.minimumStrictFill)
    let relaxationOrder: [WireDiversityIntervention.Kind] = [
      .topic, .community, .author, .publication, .domain,
    ]
    var relaxationIndex = 0
    while pass.selected.count < strictTarget, !pass.deferred.isEmpty {
      let kind = relaxationOrder[relaxationIndex % relaxationOrder.count]
      caps.relax(kind)
      interventions.append(.init(canonicalKey: "*", kind: .relaxation))
      pass = select(ranked, pageSize: pageSize, caps: caps)
      relaxationIndex += 1
    }

    var selected = pass.selected
    if selected.count < pageSize {
      selected.append(contentsOf: pass.deferred.prefix(pageSize - selected.count))
    }

    let selectedKeys = Set(selected.map(\.candidate.canonicalKey))
    let remaining = ranked.filter { !selectedKeys.contains($0.candidate.canonicalKey) }
    return WireDiversityResult(items: selected + remaining, interventions: interventions)
  }

  private struct Caps {
    var domain: Int
    var publication: Int
    var author: Int
    var topic: Int
    var community: Int

    init(policy: WireDiversityPolicy) {
      domain = policy.maxPerDomain
      publication = policy.maxPerPublication
      author = policy.maxPerAuthor
      topic = policy.maxPerTopic
      community = policy.maxPerCommunity
    }

    mutating func relax(_ kind: WireDiversityIntervention.Kind) {
      switch kind {
      case .domain: domain += 1
      case .publication: publication += 1
      case .author: author += 1
      case .topic: topic += 1
      case .community: community += 1
      case .relaxation: break
      }
    }
  }

  private static func select(
    _ ranked: [WireScoredCandidate],
    pageSize: Int,
    caps: Caps
  ) -> (
    selected: [WireScoredCandidate], deferred: [WireScoredCandidate],
    interventions: [WireDiversityIntervention]
  ) {
    var selected: [WireScoredCandidate] = []
    var deferred: [WireScoredCandidate] = []
    var interventions: [WireDiversityIntervention] = []
    var domains: [String: Int] = [:]
    var publications: [String: Int] = [:]
    var authors: [String: Int] = [:]
    var topics: [String: Int] = [:]
    var communities: [String: Int] = [:]

    for item in ranked where selected.count < pageSize {
      let candidate = item.candidate
      let violation: WireDiversityIntervention.Kind? = {
        if domains[candidate.sourceDomain, default: 0] >= caps.domain { return .domain }
        if let publication = candidate.publicationID,
          publications[publication, default: 0] >= caps.publication
        { return .publication }
        if let author = candidate.authorKey, authors[author, default: 0] >= caps.author {
          return .author
        }
        if candidate.topicKeys.contains(where: { topics[$0, default: 0] >= caps.topic }) {
          return .topic
        }
        if let community = candidate.primaryCommunityKey,
          communities[community, default: 0] >= caps.community
        { return .community }
        return nil
      }()
      if let violation {
        deferred.append(item)
        interventions.append(.init(canonicalKey: candidate.canonicalKey, kind: violation))
        continue
      }
      selected.append(item)
      domains[candidate.sourceDomain, default: 0] += 1
      if let publication = candidate.publicationID { publications[publication, default: 0] += 1 }
      if let author = candidate.authorKey { authors[author, default: 0] += 1 }
      for topic in Set(candidate.topicKeys) { topics[topic, default: 0] += 1 }
      if let community = candidate.primaryCommunityKey { communities[community, default: 0] += 1 }
    }
    return (selected, deferred, interventions)
  }
}
