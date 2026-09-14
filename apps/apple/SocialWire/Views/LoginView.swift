import SwiftUI

struct LoginView: View {
    @Environment(SocialWireAppModel.self) private var appModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var handle = ""
    @State private var isSigningIn = false
    @State private var suggestions: [LoginActorSuggestion] = []
    @State private var selectedSuggestionIndex = 0
    @State private var motionManager = LoginMotionSource()
    @FocusState private var isHandleFocused: Bool

    private var trimmedHandle: String {
        handle.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                LoginBackgroundView(motionManager: motionManager)
                ScrollView {
                    VStack(spacing: isHandleFocused ? 16 : 28) {
                        LoginHeroView(
                            motionManager: motionManager,
                            isCompact: isHandleFocused
                        )
                        signInCard
                        Text("You’ll continue securely to your account provider.")
                            .font(.footnote)
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: 480)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 36)
                    .frame(maxWidth: .infinity)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .platformInlineNavigationTitle()
            .platformHideNavigationBar()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: handle) { await updateSuggestions() }
        .onAppear {
            startDeviceMotionIfAvailable()
        }
        .onDisappear {
            motionManager.stop()
        }
        .onChange(of: reduceMotion) { _, _ in
            startDeviceMotionIfAvailable()
        }
    }

    private var signInCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Sign In").font(.title2.bold())
                Text("Use your Bluesky or AT Protocol handle.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Handle").font(.headline)
                HStack(spacing: 10) {
                    Image(systemName: "at")
                        .foregroundStyle(.indigo)
                        .accessibilityHidden(true)
                    TextField("you.bsky.social", text: $handle)
                        .platformLoginTextInputBehavior()
                        .focused($isHandleFocused)
                        .submitLabel(.continue)
                        .onSubmit(submit)
                        .accessibilityIdentifier("login-handle-field")
                }
                .padding(.horizontal, 14)
                .frame(minHeight: 50)
                .loginGlassInput(isFocused: isHandleFocused)
            }

            if appModel.authService.reauthorizationRequired {
                Label("Sign in again to approve the latest account permissions.", systemImage: "key.fill")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let errorMessage = appModel.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
            if !suggestions.isEmpty {
                LoginSuggestionList(suggestions: suggestions, selectedIndex: selectedSuggestionIndex, onSelect: select)
            }

            Button(action: submit) {
                HStack {
                    Spacer()
                    if isSigningIn {
                        ProgressView().accessibilityLabel("Signing In")
                    } else {
                        Text("Continue")
                        Image(systemName: "arrow.right")
                    }
                    Spacer()
                }
                .frame(minHeight: 28)
            }
            .disabled(trimmedHandle.isEmpty || isSigningIn)
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityIdentifier("login-continue-button")
        }
        .padding(22)
        .loginGlassCard()
        .shadow(color: .black.opacity(0.08), radius: 24, y: 12)
    }

    private func updateSuggestions() async {
        guard ATProtoResolver.loginHandleSearchQuery(handle) != nil else {
            suggestions = []
            selectedSuggestionIndex = 0
            return
        }
        do {
            try await Task.sleep(for: .milliseconds(300))
            suggestions = try await appModel.resolver.searchLoginActors(handle)
            selectedSuggestionIndex = 0
        } catch is CancellationError {
            return
        } catch {
            suggestions = []
        }
    }

    private func select(_ actor: LoginActorSuggestion) {
        handle = actor.handle
        suggestions = []
        isHandleFocused = true
    }

    private func submit() {
        guard !trimmedHandle.isEmpty, !isSigningIn else { return }
        Task {
            isSigningIn = true
            defer { isSigningIn = false }
            await appModel.signIn(handle: trimmedHandle)
        }
    }

    private func startDeviceMotionIfAvailable() {
        guard !reduceMotion else {
            motionManager.stop()
            return
        }
        motionManager.start()
    }
}
