import SwiftUI

struct LoginView: View {
    @Environment(SocialWireAppModel.self) private var appModel
    @State private var handle = ""
    @State private var isSigningIn = false
    @State private var suggestions: [LoginActorSuggestion] = []
    @State private var selectedSuggestionIndex = 0

    var body: some View {
        NavigationStack {
            ZStack {
                Color(.systemGroupedBackground)
                    .ignoresSafeArea()
                VStack(spacing: 0) {
                    Spacer(minLength: 24)
                    VStack(alignment: .center, spacing: 20) {
                        VStack(alignment: .center, spacing: 8) {
                            Text("The Social Wire")
                                .font(.largeTitle.bold())
                                .multilineTextAlignment(.center)
                            Text("Sign in with your handle.")
                                .font(.body)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                            if appModel.authService.reauthorizationRequired {
                                Label(
                                    "Sign in again to approve publishing, feedback, and photo permissions.",
                                    systemImage: "key"
                                )
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                            }
                        }

                        Text("Handle")
                            .font(.headline)
                            .multilineTextAlignment(.center)

                        TextField("you.bsky.social", text: $handle)
                            .platformLoginTextInputBehavior()
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.center)

                        if !suggestions.isEmpty {
                            VStack(spacing: 0) {
                                ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, actor in
                                    Button {
                                        select(actor)
                                    } label: {
                                        HStack(spacing: 10) {
                                            Group {
                                                if let avatar = actor.avatar, let url = URL(string: avatar) {
                                                    CachedRemoteImage(urls: [url], maxPixelSize: 96) {
                                                        Circle().fill(.quaternary)
                                                    }
                                                    .scaledToFill()
                                                } else {
                                                    Circle().fill(.quaternary)
                                                }
                                            }
                                            .frame(width: 36, height: 36)
                                            .clipShape(.circle)
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(actor.displayName?.isEmpty == false ? actor.displayName! : actor.handle)
                                                    .font(.headline)
                                                Text("@\(actor.handle)")
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                            }
                                            Spacer()
                                        }
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 8)
                                        .background(index == selectedSuggestionIndex ? Color.accentColor.opacity(0.12) : .clear)
                                        .contentShape(.rect)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityHint("Use this account to sign in")
                                }
                            }
                            .background(.regularMaterial, in: .rect(cornerRadius: 12))
                        }

                        Button {
                            Task {
                                isSigningIn = true
                                await appModel.signIn(handle: handle)
                                isSigningIn = false
                            }
                        } label: {
                            if isSigningIn {
                                ProgressView()
                                    .accessibilityLabel("Signing In")
                            } else {
                                Label("Sign In", systemImage: "person.crop.circle.badge.checkmark")
                            }
                        }
                        .disabled(handle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSigningIn)
                        .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: 560, alignment: .center)
                    .padding(24)
                    Spacer(minLength: 24)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .platformInlineNavigationTitle()
            .platformHideNavigationBar()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: handle) {
            do {
                try await Task.sleep(for: .milliseconds(250))
                suggestions = try await appModel.resolver.searchLoginActors(handle)
                selectedSuggestionIndex = 0
            } catch is CancellationError {
                return
            } catch {
                suggestions = []
            }
        }
        .onKeyPress(.downArrow) {
            guard !suggestions.isEmpty else { return .ignored }
            selectedSuggestionIndex = min(selectedSuggestionIndex + 1, suggestions.count - 1)
            return .handled
        }
        .onKeyPress(.upArrow) {
            guard !suggestions.isEmpty else { return .ignored }
            selectedSuggestionIndex = max(selectedSuggestionIndex - 1, 0)
            return .handled
        }
        .onKeyPress(.return) {
            guard suggestions.indices.contains(selectedSuggestionIndex) else { return .ignored }
            select(suggestions[selectedSuggestionIndex])
            return .handled
        }
    }

    private func select(_ actor: LoginActorSuggestion) {
        handle = actor.handle
        suggestions = []
    }
}
