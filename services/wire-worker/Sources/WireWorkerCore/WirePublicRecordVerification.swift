enum WirePublicRecordVerification: Sendable {
  case verified(WireVerifiedPublicRecord)
  case missing(WirePublicRecordObservation)
  case changed(currentCID: String, observation: WirePublicRecordObservation)
  case inactive(WirePublicRecordObservation)
}
