import SwiftUI

/// Root view: routes to login or the three-column reading experience.
struct ContentView: View {
    @EnvironmentObject var authService: ATProtoOAuthService

    var body: some View {
        Group {
            if authService.session != nil {
                MainSplitView()
            } else {
                LoginView()
            }
        }
        .animation(.default, value: authService.session != nil)
    }
}
