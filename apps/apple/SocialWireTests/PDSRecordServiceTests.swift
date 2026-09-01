import Testing
@testable import SocialWire

@Suite("PDSRecordService")
@MainActor
struct PDSRecordServiceTests {
    @Test("collection constants match lexicons")
    func collectionConstantsMatchLexicons() {
        #expect(PDSRecordService.folder == "app.thesocialwire.folder")
        #expect(PDSRecordService.publicationPrefs == "app.thesocialwire.publicationPrefs")
        #expect(PDSRecordService.preferences == "app.thesocialwire.preferences")
        #expect(PDSRecordService.latrSavedExternal == "link.latr.saved.external")
        #expect(PDSRecordService.latrSavedItem == "link.latr.saved.item")
        #expect(PDSRecordService.standardSiteSubscription == "site.standard.graph.subscription")
        #expect(PDSRecordService.standardSiteRecommend == "site.standard.graph.recommend")
        #expect(PDSRecordService.wireArticleFeedback == "app.thesocialwire.wireFeedback")
        #expect(PDSRecordService.skyreaderFeedSubscription == "app.skyreader.feed.subscription")
    }
}
