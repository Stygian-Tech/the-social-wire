enum CircleStableHash {
  /// FNV-1a is used only as a deterministic final tie-breaker, never as a privacy boundary.
  static func value(_ value: String) -> UInt64 {
    var hash: UInt64 = 14_695_981_039_346_656_037
    for byte in value.utf8 {
      hash ^= UInt64(byte)
      hash &*= 1_099_511_628_211
    }
    return hash
  }
}
