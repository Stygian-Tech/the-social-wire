import SwiftUI

struct RootView: View {
    @Environment(SocialWireAppModel.self) private var appModel

    var body: some View {
        Group {
            if appModel.isSignedIn {
                MainSplitView()
            } else {
                LoginView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
        .alert("Something went wrong", isPresented: Binding(
            get: { appModel.errorMessage != nil },
            set: { if !$0 { appModel.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { appModel.errorMessage = nil }
        } message: {
            Text(appModel.errorMessage ?? "Unknown error")
        }
    }
}
