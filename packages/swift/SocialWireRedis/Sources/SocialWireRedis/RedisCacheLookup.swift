public enum RedisCacheLookup<Value: Sendable>: Sendable {
  case fresh(Value)
  case stale(Value)
  case miss
}
