import SwiftUI

@main
struct SocialWireApp: App {
    @State private var appModel = SocialWireAppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appModel)
                .tint(.indigo)
                .task {
                    await appModel.restoreSession()
                }
                .onOpenURL { url in
                    Task { await appModel.handleOAuthCallback(url) }
                }
        }
    }
}
