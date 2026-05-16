import SwiftUI

struct LoginView: View {
    @Environment(SocialWireAppModel.self) private var appModel
    @State private var handle = ""
    @State private var isSigningIn = false

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
                        }

                        Text("Handle")
                            .font(.headline)
                            .multilineTextAlignment(.center)

                        TextField("you.bsky.social", text: $handle)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.center)

                        Button {
                            Task {
                                isSigningIn = true
                                await appModel.signIn(handle: handle)
                                isSigningIn = false
                            }
                        } label: {
                            if isSigningIn {
                                ProgressView()
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
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .navigationBar)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
