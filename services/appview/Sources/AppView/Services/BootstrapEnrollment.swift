/// Enrollment may outlive the response. Checking its completion must never join its task.
actor BootstrapEnrollment {
  private(set) var isFinished = false

  static func start(_ operation: @escaping @Sendable () async -> Void) -> BootstrapEnrollment {
    let enrollment = BootstrapEnrollment()
    Task {
      await operation()
      await enrollment.finish()
    }
    return enrollment
  }

  private func finish() {
    isFinished = true
  }
}
