enum WireStandardSiteDocumentError: Error, Equatable {
  case malformedDocument
  case unaddressableDocument
  case invalidPublication
  case unresolvedPublication
}
