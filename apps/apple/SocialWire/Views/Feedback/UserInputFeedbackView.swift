import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct UserInputFeedbackView: View {
    @Environment(SocialWireAppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var details = ""
    @State private var selectedTagValues = Set<String>()
    @State private var availableTags = UserInputTag.localDefaults
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var photos: [UserInputFeedbackPhoto] = []
    @State private var board: UserInputBoardReference?
    @State private var isLoadingBoard = false
    @State private var submissionProgress: UserInputSubmissionProgress?
    @State private var successURL: URL?
    @State private var errorMessage: String?

    var body: some View {
        Form {
            if let successURL {
                successSection(url: successURL)
            } else {
                feedbackForm
            }
        }
        .navigationTitle("Send Feedback")
        .platformInlineNavigationTitle()
        .toolbar {
            if successURL != nil {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task { await loadBoard() }
        .onChange(of: photoItems) { _, items in
            Task { await loadPhotos(from: items) }
        }
        .alert("Couldn’t Send Feedback", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "Try again shortly.")
        }
    }

    @ViewBuilder
    private var feedbackForm: some View {
        Section {
            TextField("Title", text: $title)
                .accessibilityLabel("Feedback Title")

            TextEditor(text: $details)
                .frame(minHeight: 120)
                .accessibilityLabel("Feedback Details")
        } header: {
            Text("What would you like us to know?")
        }

        Section("Tags") {
            if isLoadingBoard && board == nil {
                ProgressView("Loading Tags…")
            }
            ForEach(availableTags) { tag in
                Toggle(tag.label, isOn: tagBinding(tag.value))
            }
        }

        Section("Photos") {
            PhotosPicker(
                selection: $photoItems,
                maxSelectionCount: UserInputFeedbackService.maximumPhotoCount,
                matching: .images
            ) {
                Label("Add Photos", systemImage: "photo.badge.plus")
            }
            .disabled(isSubmitting)

            ForEach(photos) { photo in
                photoRow(photo)
            }

            Text("Attach up to four images. Photos are uploaded to your AT Protocol account with the public feedback record.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }

        Section {
            Link(destination: UserInputFeedbackService.boardURL) {
                Label("View the Feedback Board", systemImage: "arrow.up.right.square")
            }
        } footer: {
            Text("Your feedback, selected tags, and attached photos will be public on UserInput. Don’t include private or sensitive information.")
        }

        Section {
            Button {
                Task { await submit() }
            } label: {
                HStack {
                    Text("Send Feedback")
                    Spacer()
                    if isSubmitting {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
            }
            .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSubmitting)

            if let submissionProgress {
                Text(progressLabel(submissionProgress))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func successSection(url: URL) -> some View {
        Section {
            ContentUnavailableView {
                Label("Feedback Sent", systemImage: "checkmark.circle.fill")
            } description: {
                Text("Thanks for helping improve The Social Wire.")
            } actions: {
                Link("View Feedback", destination: url)
            }
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, minHeight: 260)
        }
    }

    private func photoRow(_ photo: UserInputFeedbackPhoto) -> some View {
        HStack(spacing: 12) {
            if let image = PlatformImage(data: photo.data) {
                Image(platformImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 52, height: 52)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .accessibilityHidden(true)
            }
            Text(photo.name)
                .lineLimit(1)
            Spacer()
            Button("Remove", systemImage: "trash", role: .destructive) {
                removePhoto(photo)
            }
            .labelStyle(.iconOnly)
            .disabled(isSubmitting)
        }
    }

    private var isSubmitting: Bool { submissionProgress != nil }

    private func tagBinding(_ value: String) -> Binding<Bool> {
        Binding(
            get: { selectedTagValues.contains(value) },
            set: { selected in
                if selected {
                    selectedTagValues.insert(value)
                } else {
                    selectedTagValues.remove(value)
                }
            }
        )
    }

    private func loadBoard() async {
        guard board == nil else { return }
        isLoadingBoard = true
        defer { isLoadingBoard = false }
        do {
            let loadedBoard = try await appModel.userInputFeedbackService.fetchBoardReference()
            board = loadedBoard
            if !loadedBoard.tags.isEmpty {
                availableTags = loadedBoard.tags
            }
        } catch {
            // Keep the local tag catalog available. Submission retries the board request.
        }
    }

    private func loadPhotos(from items: [PhotosPickerItem]) async {
        var loaded: [UserInputFeedbackPhoto] = []
        for (index, item) in items.prefix(UserInputFeedbackService.maximumPhotoCount).enumerated() {
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            let contentType = item.supportedContentTypes.first { $0.conforms(to: .image) }
            loaded.append(UserInputFeedbackPhoto(
                data: data,
                mimeType: contentType?.preferredMIMEType ?? "image/jpeg",
                name: "Photo \(index + 1)"
            ))
        }
        photos = loaded
    }

    private func removePhoto(_ photo: UserInputFeedbackPhoto) {
        guard let index = photos.firstIndex(where: { $0.id == photo.id }) else { return }
        photos.remove(at: index)
        if photoItems.indices.contains(index) {
            photoItems.remove(at: index)
        }
    }

    private func submit() async {
        submissionProgress = .posting
        defer {
            if successURL == nil {
                submissionProgress = nil
            }
        }
        do {
            let submissionBoard: UserInputBoardReference
            if let board {
                submissionBoard = board
            } else {
                submissionBoard = try await appModel.userInputFeedbackService.fetchBoardReference()
                board = submissionBoard
            }
            let input = UserInputFeedbackInput(
                title: title,
                body: details,
                tags: availableTags
                    .filter { selectedTagValues.contains($0.value) }
                    .map(\.value),
                photos: photos
            )
            successURL = try await appModel.userInputFeedbackService.submit(input, board: submissionBoard) { progress in
                submissionProgress = progress
            }
            submissionProgress = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func progressLabel(_ progress: UserInputSubmissionProgress) -> String {
        switch progress {
        case let .uploadingPhoto(completed, total):
            "Uploading Photo \(min(completed + 1, total)) of \(total)…"
        case .posting:
            "Posting Feedback…"
        }
    }
}
