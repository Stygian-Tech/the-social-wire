import Testing

@testable import WireWorkerCore

struct WireDeclaredLanguageValidatorTests {
  @Test("rejects an English declaration contradicted by Japanese content")
  func rejectsJapaneseAsEnglish() {
    #expect(
      WireDeclaredLanguageValidator.validatedLanguageCode(
        declaredLanguageCode: "en-US",
        title: "業務時間外もAIに働いてもらう話",
        summary: "仕事の進め方と新しいツールについて説明します"
      ) == nil
    )
  }

  @Test("rejects an English declaration contradicted by Tagalog content")
  func rejectsTagalogAsEnglish() {
    #expect(
      WireDeclaredLanguageValidator.validatedLanguageCode(
        declaredLanguageCode: "en",
        title: "PCG nagsagawa ng malawakang preemptive evacuation sa mga lugar",
        summary: "Mga lugar na apektado ng Habagat ang kasama sa ulat"
      ) == nil
    )
  }

  @Test("accepts corroborated English and normalizes the locale")
  func acceptsEnglish() {
    #expect(
      WireDeclaredLanguageValidator.validatedLanguageCode(
        declaredLanguageCode: "en_US",
        title: "How the new system will work",
        summary: "The guide is for people who work with the service"
      ) == "en"
    )
  }

  @Test("accepts corroborated French")
  func acceptsFrench() {
    #expect(
      WireDeclaredLanguageValidator.validatedLanguageCode(
        declaredLanguageCode: "fr",
        title: "Comment utiliser le service",
        summary: "Une présentation avec les détails du projet"
      ) == "fr"
    )
  }

  @Test("fails closed when Latin content is too weak to distinguish")
  func rejectsAmbiguousLatinContent() {
    #expect(
      WireDeclaredLanguageValidator.validatedLanguageCode(
        declaredLanguageCode: "en",
        title: "Product update",
        summary: nil
      ) == nil
    )
  }
}
