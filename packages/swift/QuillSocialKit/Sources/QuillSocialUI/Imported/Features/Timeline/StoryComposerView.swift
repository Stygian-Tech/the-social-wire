#if os(iOS)
import Feeds
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct StoryComposerView: View {
    let stories: StoryModel
    @Environment(\.dismiss) private var dismiss
    @State private var model = StoryComposerModel()
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var isLoadingPhoto = false
    @State private var photoError: String?
    @State private var publicationFeedback = 0
    @State private var isCameraPresented: Bool
    @State private var cameraFeedback = 0

    init(stories: StoryModel, startsWithCamera: Bool = false) {
        self.stories = stories
        let cameraIsAvailable = UIImagePickerController.isSourceTypeAvailable(.camera)
        _isCameraPresented = State(initialValue: startsWithCamera && cameraIsAvailable)
        _photoError = State(initialValue: startsWithCamera && !cameraIsAvailable ? "A Camera Is Not Available on This Device." : nil)
    }

    var body: some View {
        let photoButtonTitle = model.imageData == nil ? "Choose Photo" : "Replace Photo"
        NavigationStack {
            VStack(spacing: 20) {
                if let data = model.imageData, let image = UIImage(data: data) {
                    Image(uiImage: image)
                        .resizable().scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView("Add a Photo", systemImage: "photo", description: Text("Share a photo story for 24 hours."))
                }
                if isLoadingPhoto { ProgressView("Preparing Photo") }
                if model.isPublishing { ProgressView("Publishing Story") }
                if let photoError { Text(photoError).foregroundStyle(.red) }
                if model.didFail {
                    Text("Your Story Could Not Be Published. Try Again.")
                        .foregroundStyle(.red)
                }
                HStack {
                    Button("Take Photo", systemImage: "camera") {
                        openCamera()
                    }
                    .disabled(model.isPublishing || isLoadingPhoto)

                    PhotosPicker(selection: $selectedPhoto, matching: .images) {
                        Label(photoButtonTitle, systemImage: "photo")
                    }
                    .disabled(model.isPublishing || isLoadingPhoto)
                }
                .buttonStyle(.bordered)
                Text("Visible for 24 Hours").font(.footnote).foregroundStyle(.secondary)
            }
            .padding()
            .navigationTitle("New Story")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(model.isPublishing)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Publish") {
                        Task {
                            if await model.publish(using: stories) {
                                publicationFeedback += 1
                                dismiss()
                            }
                        }
                    }
                    .disabled(model.imageData == nil || model.isPublishing || isLoadingPhoto)
                }
            }
            .interactiveDismissDisabled(model.isPublishing)
            .sensoryFeedback(.success, trigger: publicationFeedback)
            .sensoryFeedback(.impact, trigger: cameraFeedback)
            .task(id: selectedPhoto) { await preparePhoto() }
            .fullScreenCover(isPresented: $isCameraPresented) {
                StoryCameraView { data in prepareCapturedPhoto(data) }
            }
        }
    }

    private func preparePhoto() async {
        guard let selectedPhoto else { return }
        isLoadingPhoto = true
        photoError = nil
        defer { isLoadingPhoto = false }
        do {
            guard let data = try await selectedPhoto.loadTransferable(type: Data.self),
                  let image = UIImage(data: data),
                  let jpeg = image.jpegData(compressionQuality: 0.9),
                  let prepared = ComposerImageProcessor.prepare(jpeg, mimeType: "image/jpeg") else {
                photoError = "This Photo Could Not Be Prepared. Choose Another Photo."
                return
            }
            try Task.checkCancellation()
            model.selectPhoto(data: prepared.data, mimeType: prepared.mimeType)
        } catch {
            guard !Task.isCancelled else { return }
            photoError = "This Photo Could Not Be Loaded. Try Again."
        }
    }

    private func prepareCapturedPhoto(_ data: Data) {
        photoError = nil
        guard let prepared = ComposerImageProcessor.prepare(data, mimeType: "image/jpeg") else {
            photoError = "This Photo Could Not Be Prepared. Take Another Photo."
            return
        }
        model.selectPhoto(data: prepared.data, mimeType: prepared.mimeType)
    }

    private func openCamera() {
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            photoError = "A Camera Is Not Available on This Device."
            return
        }
        isCameraPresented = true
        cameraFeedback += 1
    }
}

#endif
