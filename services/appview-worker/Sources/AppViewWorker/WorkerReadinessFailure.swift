struct WorkerReadinessFailure: Error, Sendable, Equatable {
  let reason: WorkerReadinessError
  let diagnostics: WorkerReadinessDiagnostics
}
