import OperationsCore

actor MutationAuditRecorderProbe {
  private var audits: [OperationsMutationAudit] = []

  func record(_ audit: OperationsMutationAudit) {
    audits.append(audit)
  }

  func count() -> Int { audits.count }
}
