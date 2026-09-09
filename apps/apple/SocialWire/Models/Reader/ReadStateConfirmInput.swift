struct ReadStateConfirmInput: Encodable {
    let manifestCid: String
    let expectedLegacyRevision: Int64?
}
