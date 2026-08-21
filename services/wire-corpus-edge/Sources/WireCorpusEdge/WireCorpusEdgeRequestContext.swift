import Hummingbird

struct WireCorpusEdgeRequestContext: RequestContext {
  var coreContext: CoreRequestContextStorage

  init(source: Source) {
    self.coreContext = .init(source: source)
  }
}
