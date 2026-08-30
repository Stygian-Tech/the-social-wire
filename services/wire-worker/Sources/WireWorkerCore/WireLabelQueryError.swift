enum WireLabelQueryError: Error, Equatable, Sendable {
  case invalidURL
  case unexpectedStatus(Int)
  case invalidResponse
  case paginationLimit
  case repeatedCursor
  case incompleteResponse
  case staleRefresh
  case refreshTimedOut
}
