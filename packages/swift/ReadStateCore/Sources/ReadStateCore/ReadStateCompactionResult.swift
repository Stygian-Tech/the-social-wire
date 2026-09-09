public struct ReadStateCompactionResult: Sendable {
  /// Surviving fragments retain original metadata; receipts retain whole-intent retry evidence.
  public let operations: [ReadStateOperation]
  public let receipts: [ReadStateLegacyActionReceipt]
}
