enum PodcastDirectoryError: Error, Equatable {
  case invalidQuery
  case invalidRequest
  case unavailable
  case busy
}
