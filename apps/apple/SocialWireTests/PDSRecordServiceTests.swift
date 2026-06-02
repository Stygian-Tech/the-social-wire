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
        #expect(PDSRecordService.entryReadState == "app.thesocialwire.entryReadState")
        #expect(PDSRecordService.latrSavedExternal == "link.latr.saved.external")
        #expect(PDSRecordService.latrSavedItem == "link.latr.saved.item")
        #expect(PDSRecordService.standardSiteSubscription == "site.standard.graph.subscription")
        #expect(PDSRecordService.skyreaderFeedSubscription == "app.skyreader.feed.subscription")
    }
}
