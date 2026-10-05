import Foundation
import Testing
@testable import FinanceCore

struct FinanceResolverSectorContextTests {
  @Test("generic sector words never admit unrelated stories without economic corroboration")
  func unrelatedSectorMentions() {
    let helmet = FinanceResolver.analyze(
      title: "The number of people in the comments defending her not wearing a helmet and “skater culture”…",
      summary: "This woman is a professional with a large following on social media. She has to wear a helmet in official competition but not in most of her videos. It’s absolutely moronic. She was probably very close to a TBI and the end of her career. This makes me sick to my stomach and you can [...]", catalog: [])
    #expect(!helmet.eligible)
    for text in ["How to conserve energy during a morning workout", "Cooking vegetables in olive oil at home", "Consumer media habits change during school holidays"] {
      #expect(!FinanceResolver.analyze(title: text, catalog: []).eligible)
    }
  }
  @Test("sector business reporting and macro news remain eligible without instruments")
  func sectorReporting() {
    for title in ["Technology industry annual sales increased", "Industrial production rises as supply constraints ease", "Healthcare sector faces pharmaceutical supply reforms", "Inflation slows after central bank interest rate changes"] {
      let result = FinanceResolver.analyze(title: title, catalog: [])
      #expect(result.eligible)
      #expect(result.associations.isEmpty)
      #expect(result.resolverVersion == FinanceResolver.version)
    }
  }
  @Test("old private analysis decodes without a resolver revision and must be revalidated")
  func oldAnalysis() throws {
    let old = try JSONDecoder().decode(FinanceArticleAnalysis.self,
      from: Data(#"{"eligible":true,"materiality":"reporting","associations":[],"sectorIDs":[]}"#.utf8))
    #expect(old.resolverVersion == nil)
  }
}
