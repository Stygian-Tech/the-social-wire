import Foundation

public actor RedisRankingStore {
  private let commands: any RedisCommandClient
  private let namespace: RedisKeyNamespace

  public init(commands: any RedisCommandClient, namespace: RedisKeyNamespace) {
    self.commands = commands
    self.namespace = namespace
  }

  public func upsert(
    _ candidates: [RedisRankingCandidate],
    scope: RedisRankingScope,
    window: RedisRankingWindow
  ) async throws {
    guard !candidates.isEmpty else { return }
    let key = rankingKey(scope: scope, window: window)
    var arguments: [RedisCommandValue] = [.data(Data(key.utf8))]
    for candidate in candidates {
      arguments.append(.data(Data(candidate.score.description.utf8)))
      arguments.append(.data(Data(candidate.contentId.utf8)))
    }
    _ = try await commands.execute(command: "ZADD", arguments: arguments)
    _ = try await commands.execute(
      command: "PEXPIRE",
      arguments: [.data(Data(key.utf8)), .integer(Int(window.expiration * 1_000))]
    )
  }

  public func remove(
    contentIds: [String],
    scope: RedisRankingScope,
    window: RedisRankingWindow
  ) async throws {
    guard !contentIds.isEmpty else { return }
    let arguments = [RedisCommandValue.data(Data(rankingKey(scope: scope, window: window).utf8))]
      + contentIds.map { .data(Data($0.utf8)) }
    _ = try await commands.execute(command: "ZREM", arguments: arguments)
  }

  public func top(
    limit: Int,
    scope: RedisRankingScope,
    window: RedisRankingWindow
  ) async throws -> [RedisRankingCandidate] {
    guard limit > 0 else { return [] }
    let result = try await commands.execute(
      command: "ZREVRANGE",
      arguments: [
        .data(Data(rankingKey(scope: scope, window: window).utf8)),
        .integer(0),
        .integer(limit - 1),
        .data(Data("WITHSCORES".utf8)),
      ]
    )
    guard case .array(let values) = result, values.count.isMultiple(of: 2) else {
      throw RedisRankingError.malformedResponse
    }
    return try stride(from: 0, to: values.count, by: 2).map { index in
      guard let contentId = values[index].string,
            let scoreString = values[index + 1].string,
            let score = Double(scoreString)
      else {
        throw RedisRankingError.malformedResponse
      }
      return try RedisRankingCandidate(contentId: contentId, score: score)
    }
  }

  public func trim(
    keeping limit: Int,
    scope: RedisRankingScope,
    window: RedisRankingWindow
  ) async throws {
    guard limit >= 0 else { return }
    _ = try await commands.execute(
      command: "ZREMRANGEBYRANK",
      arguments: [
        .data(Data(rankingKey(scope: scope, window: window).utf8)),
        .integer(0),
        .integer(-(limit + 1)),
      ]
    )
  }

  private func rankingKey(scope: RedisRankingScope, window: RedisRankingWindow) -> String {
    switch scope {
    case .global(let feed):
      namespace.key(domain: "rank", safeComponents: [feed, window.rawValue])
    case .viewerCircle(let feed, let viewerDid):
      namespace.key(
        domain: "rank",
        safeComponents: [feed, window.rawValue],
        identifiers: [viewerDid]
      )
    }
  }
}
