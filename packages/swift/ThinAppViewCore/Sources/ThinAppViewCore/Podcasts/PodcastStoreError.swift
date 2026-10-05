public enum PodcastStoreError: Error {
  case revisionConflict, invalidState, notFound, invalidRequest
}
