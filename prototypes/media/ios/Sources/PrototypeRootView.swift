import SwiftUI

struct PrototypeRootView: View {
    @State private var darkMode = false
    @State private var composing = false
    var body: some View {
        TabView {
            NavigationStack { PrototypeHomeView().toolbar { composeButton; appearanceButton } }
                .tabItem { Label("Home", systemImage: "house") }
            NavigationStack { PrototypeMediaView().toolbar { composeButton; appearanceButton } }
                .tabItem { Label("Media", systemImage: "play.rectangle") }
        }
        .sheet(isPresented: $composing) { PrototypeComposerView() }
        .tint(.purple)
        .preferredColorScheme(darkMode ? .dark : .light)
    }
    private var composeButton: some View {
        Button("Compose Post", systemImage: "square.and.pencil") { composing = true }
            .labelStyle(.iconOnly)
    }
    private var appearanceButton: some View {
        Button("Toggle Appearance", systemImage: darkMode ? "sun.max" : "moon") { darkMode.toggle() }
            .labelStyle(.iconOnly)
    }
}
