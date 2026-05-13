import SwiftUI

/// Sign-in screen — accepts an ATProto handle and initiates OAuth.
struct LoginView: View {
    @EnvironmentObject var authService: ATProtoOAuthService
    @State private var handle = ""
    @State private var isSigningIn = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 32) {
            VStack(spacing: 8) {
                Text("The Social Wire")
                    .font(.largeTitle.bold())
                Text("Sign in with your Bluesky or ATProto account")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Handle")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextField("you.bsky.social", text: $handle)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.emailAddress)
                    .onSubmit { signIn() }
            }

            if let error = errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Button(action: signIn) {
                if isSigningIn {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else {
                    Text("Continue with ATProto")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(handle.trimmingCharacters(in: .whitespaces).isEmpty || isSigningIn)

            Text("Your reading preferences are stored on your own PDS, not on our servers.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: 360)
    }

    private func signIn() {
        let trimmed = handle.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        isSigningIn = true
        errorMessage = nil

        Task {
            do {
                try await authService.signIn(handle: trimmed)
            } catch {
                errorMessage = error.localizedDescription
                isSigningIn = false
            }
        }
    }
}
