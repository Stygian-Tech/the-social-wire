enum WireStandardSiteDocumentError: Error, Equatable {
  case malformedDocument
  case invalidPublication
  case unresolvedPublication
}
