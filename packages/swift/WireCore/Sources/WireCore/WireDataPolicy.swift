import Foundation

public enum WireDataPolicy {
  public static let signalRetention: TimeInterval = 7 * 86_400
  public static let appliedInboxRetention: TimeInterval = 86_400
  public static let deadLetterRetention: TimeInterval = 14 * 86_400
  public static let itemRetention: TimeInterval = 30 * 86_400
  public static let activeActorRetention: TimeInterval = 30 * 86_400
  public static let followEdgeRetention: TimeInterval = 30 * 86_400
  public static let communityAssignmentRetention: TimeInterval = 7 * 86_400
  public static let clusteringCadence: TimeInterval = 6 * 3_600
  public static let maximumActiveActors = 250_000
  public static let maximumFollowEdgesPerActor = 200
  public static let minimumGlobalCandidates = 50
  public static let minimumLocaleCandidates = 50
  public static let diverseFirstPageCount = 50
}
