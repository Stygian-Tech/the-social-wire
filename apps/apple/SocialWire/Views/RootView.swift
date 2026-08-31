import SwiftData
import SwiftUI

struct RootView: View {
    @Environment(SocialWireAppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
#if DEBUG
            if isNewsShellUITest {
                NewsShellUITestHarness()
            } else if appModel.isSignedIn {
                NewsShellView()
            } else {
                LoginView()
            }
#else
            if appModel.isSignedIn {
                NewsShellView()
            } else {
                LoginView()
            }
#endif
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
        .task {
#if DEBUG
            guard !isNewsShellUITest else { return }
#endif
            appModel.configureReaderPersistence(modelContext: modelContext)
            await appModel.restoreSession()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active, appModel.isSignedIn else { return }
            Task { await appModel.syncCrossClientReadState() }
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { appModel.errorMessage != nil },
            set: { if !$0 { appModel.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { appModel.errorMessage = nil }
        } message: {
            Text(appModel.errorMessage ?? "Unknown error")
        }
    }

#if DEBUG
    private var isNewsShellUITest: Bool {
        ProcessInfo.processInfo.arguments.contains("--ui-testing-news-shell")
    }
#endif
}
