import Foundation
import Testing
@testable import SocialWire

@Suite("UserInput feedback contract")
@MainActor
struct UserInputFeedbackServiceTests {
    @Test("UserInput include scope permits text feedback")
    func includeScopePermitsTextFeedback() throws {
        try UserInputFeedbackService.requirePermissions(
            scope: "atproto include:app.userinput.authFull",
            photoMimeTypes: []
        )
    }

    @Test("Collection create scope permits text feedback")
    func collectionCreateScopePermitsTextFeedback() throws {
        try UserInputFeedbackService.requirePermissions(
            scope: "repo:app.userinput.discussion?action=create",
            photoMimeTypes: []
        )
    }

    @Test("Photo feedback requires a matching blob scope")
    func photosRequireBlobScope() {
        #expect(throws: UserInputFeedbackError.reauthorizationRequired) {
            try UserInputFeedbackService.requirePermissions(
                scope: "include:app.userinput.authFull",
                photoMimeTypes: ["image/jpeg"]
            )
        }
    }

    @Test("Wildcard image blob scope permits photo feedback")
    func wildcardBlobScopePermitsPhotos() throws {
        try UserInputFeedbackService.requirePermissions(
            scope: "include:app.userinput.authFull blob:image/*",
            photoMimeTypes: ["image/jpeg", "image/png"]
        )
    }

    @Test("Discussion records map to the public UserInput URL")
    func discussionURL() throws {
        let url = try #require(UserInputFeedbackService.discussionURL(
            uri: "at://did:plc:viewer/app.userinput.discussion/3abc"
        ))
        #expect(url.absoluteString == "https://userinput.app/d/did%3Aplc%3Aviewer/3abc?lang=en")
    }

    @Test("Other collections do not map to discussion URLs")
    func rejectsOtherCollections() {
        #expect(UserInputFeedbackService.discussionURL(
            uri: "at://did:plc:viewer/app.userinput.upvote/3abc"
        ) == nil)
    }
}
