struct ReadStateExportInput: Encodable {
    let cursor: String?
    let expectedLegacyRevision: Int64?
    let limit: Int
}
