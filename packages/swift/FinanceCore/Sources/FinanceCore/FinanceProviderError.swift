public enum FinanceProviderError: Error, Equatable, Sendable {
  case httpStatus(Int), invalidResponse, invalidRequest, responseTooLarge
}
