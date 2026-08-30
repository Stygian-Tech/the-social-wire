public enum CircleRelationship: Equatable, Sendable {
  case direct
  case oneHop(pathCount: Int)

  public var weight: Double {
    switch self {
    case .direct:
      1
    case .oneHop(let pathCount):
      min(0.8, 0.5 + (Double(max(1, pathCount) - 1) * 0.1))
    }
  }
}
