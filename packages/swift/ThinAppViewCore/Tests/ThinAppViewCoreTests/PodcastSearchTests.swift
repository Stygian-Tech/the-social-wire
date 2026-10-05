import Foundation
import Testing
@testable import ThinAppViewCore

struct PodcastSearchTests {
  @Test func matchesPublisherProseWithoutCaseOrDiacritics() {
    #expect(PodcastSearch.matches("CAFE Science", title: "Café", description: "Science Today"))
    #expect(PodcastSearch.matches("SAM", title: "Show", description: nil, hosts: [PodcastPerson(name: "Sam")]))
    #expect(!PodcastSearch.matches("science missing", title: "Science", description: nil))
    #expect(PodcastSearch.matches("東京", title: "東京 Podcast", description: nil))
  }

  @Test func olderLibraryResponsesDecodeWithoutDirectoryFields() throws {
    let page = try JSONDecoder().decode(PodcastSearchResponse.self, from: Data(#"{"shows":[],"episodes":[],"hasMore":false}"#.utf8))
    #expect(page.candidates.isEmpty && page.directoryLimit == nil)
  }

  @Test func rejectsInvalidQueriesAndUnsupportedScope() throws {
    for request in [PodcastSearchRequest(query: " "), PodcastSearchRequest(query: "a"), PodcastSearchRequest(query: String(repeating: "a", count: 201)), PodcastSearchRequest(query: "show", scope: "unknown"), PodcastSearchRequest(query: "show", kind: "unknown"), PodcastSearchRequest(query: "show", limit: 0), PodcastSearchRequest(query: "show", limit: 101)] {
      #expect(throws: PodcastStoreError.invalidRequest) { try request.validate() }
    }
    try PodcastSearchRequest(query: "  show  ", limit: 100).validate()
  }

  @Test func cursorIsBoundToViewerQueryAndFiltersWithoutStoringTheQuery() throws {
    let request = PodcastSearchRequest(query: "Private Needle", kind: "episodes", showId: "show")
    let binding = try PodcastSearch.binding(viewer: "did:plc:owner", request: request)
    let encoded = try PodcastSearchCursor(binding: binding, entity: 1, id: "episode").encoded()
    #expect(try PodcastSearchCursor.decode(encoded, binding: binding)?.id == "episode")
    let body = try #require(Data(base64Encoded: encoded))
    #expect(!String(decoding: body, as: UTF8.self).contains("Private Needle"))
    for other in [PodcastSearchRequest(query: "Different", kind: "episodes", showId: "show"), PodcastSearchRequest(query: request.query, kind: "shows", showId: "show"), PodcastSearchRequest(query: request.query, kind: "episodes", showId: "another")] {
      let wrong = try PodcastSearch.binding(viewer: "did:plc:owner", request: other)
      #expect(throws: PodcastStoreError.invalidRequest) { try PodcastSearchCursor.decode(encoded, binding: wrong) }
    }
    let foreign = try PodcastSearch.binding(viewer: "did:plc:other", request: request)
    #expect(throws: PodcastStoreError.invalidRequest) { try PodcastSearchCursor.decode(encoded, binding: foreign) }
    #expect(throws: PodcastStoreError.invalidRequest) { try PodcastSearchCursor.decode("bad", binding: binding) }
  }
}
