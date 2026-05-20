import Testing
@testable import SocialWire

@Suite("PDSRecordService")
@MainActor
struct PDSRecordServiceTests {
    @Test("collection constants match lexicons")
    func collectionConstantsMatchLexicons() {
        #expect(PDSRecordService.folder == "com.thesocialwire.folder")
        #expect(PDSRecordService.publicationPrefs == "com.thesocialwire.publicationPrefs")
        #expect(PDSRecordService.preferences == "com.thesocialwire.preferences")
        #expect(PDSRecordService.entryReadState == "com.thesocialwire.entryReadState")
        #expect(PDSRecordService.latrSavedExternal == "com.latr.saved.external")
        #expect(PDSRecordService.latrSavedItem == "com.latr.saved.item")
        #expect(PDSRecordService.standardSiteSubscription == "site.standard.graph.subscription")
        #expect(PDSRecordService.skyreaderFeedSubscription == "app.skyreader.feed.subscription")
    }
}
