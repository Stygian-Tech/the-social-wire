import SwiftUI

@main
struct SocialWireApp: App {
    @StateObject private var authService = ATProtoOAuthService()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(authService)
                .onOpenURL { url in
                    // Handle ATProto OAuth callback redirect
                    Task {
                        await authService.handleCallbackURL(url)
                    }
                }
        }
    }
}
