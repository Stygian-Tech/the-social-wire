#if os(iOS)
import PhotosUI
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct PostComposerView: View {
    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss
    @Query private var settings: [AppSettings]
    @State private var model: PostComposerModel
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showsFileImporter = false
    @State private var showsGIFPicker = false
    @State private var attachmentForAltText: PostComposerModel.Attachment?
    @State private var isGeneratingAltTextForAll = false
    @State private var imagePreparationCompleted = 0
    @State private var imagePreparationTotal = 0
    @FocusState private var focusedDraftID: UUID?
    private let onPosted: () -> Void

    init(
        context: PostComposerModel.Context = .post,
        onPosted: @escaping () -> Void = {}
    ) {
        _model = State(initialValue: PostComposerModel(context: context))
        self.onPosted = onPosted
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            if let post = model.context.referencedPost {
                                ComposerReferencedPostView(title: contextTitle, post: post)
                            }
                            ForEach(model.drafts) { draft in
                                draftComposer(draft)
                                    .id(draft.id)
                            }
                        }
                        .padding(16)
                    }
                    .scrollDismissesKeyboard(.immediately)
                    .onChange(of: focusedDraftID) { _, id in
                        if let id {
                            model.activate(id)
                            proxy.scrollTo(id, anchor: .top)
                        }
                    }
                    .onChange(of: model.drafts.count) { _, _ in
                        proxy.scrollTo(model.activeDraftID, anchor: .top)
                    }
                }
                .frame(minHeight: 0, maxHeight: .infinity)
                composerControls
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)
            }
            .roundedNavigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Post") {
                        Task {
                            await model.send(
                                using: services.postActionSource,
                                requiringAltText: requiresAltText
                            )
                        }
                    }
                    .disabled(!model.canPost(requiringAltText: requiresAltText) || model.isSending)
                }
            }
        }
        .sheet(item: $attachmentForAltText) { attachment in
            ComposerAltTextView(
                attachment: attachment,
                allowsGeneration: allowsComposerAltTextGeneration
            ) { altText in
                model.updateAltText(altText, for: attachment.id)
            }
        }
        .task {
            await Task.yield()
            focusedDraftID = model.drafts.first?.id
        }
        .onChange(of: photoItems) { _, items in
            Task { await importPhotos(items) }
        }
        .onChange(of: model.didPost) { _, didPost in
            if didPost {
                onPosted()
                dismiss()
            }
        }
        .fileImporter(
            isPresented: $showsFileImporter,
            allowedContentTypes: [.image],
            allowsMultipleSelection: true
        ) { result in
            Task { await importFiles(result) }
        }
        .sheet(isPresented: $showsGIFPicker) {
            KlipyGIFPicker { gif in
                showsGIFPicker = false
                Task { await importGIF(gif) }
            }
        }
        .alert(composerErrorTitle, isPresented: errorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
        .background {
            if #unavailable(iOS 26) {
                ComposerRotationFocusGuard { focusedDraftID = nil }
                    .frame(width: 0, height: 0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .interactiveDismissDisabled(model.isSending)
    }

    private var navigationTitle: LocalizedStringResource {
        switch model.context {
        case .post: "New Post"
        case .reply: "Reply"
        case .quote: "Quote Post"
        }
    }

    private var contextTitle: LocalizedStringResource {
        switch model.context {
        case .post: "Post"
        case .reply: "Replying To"
        case .quote: "Quoting"
        }
    }

    private var firstPrompt: LocalizedStringKey {
        switch model.context {
        case .post: "What’s happening?"
        case .reply: "Write a reply"
        case .quote: "Add a comment"
        }
    }

    private var composerControls: some View {
        VStack(spacing: 4) {
            if model.isSending {
                HStack {
                    ProgressView()
                    Text("Publishing").font(.caption).foregroundStyle(.secondary)
                }
            } else if imagePreparationTotal > 0 {
                ProgressView(value: Double(imagePreparationCompleted), total: Double(imagePreparationTotal)) {
                    Text("\(imagePreparationCompleted) of \(imagePreparationTotal)").font(.caption)
                }
            }
            attachmentBar
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private var attachmentBar: some View {
        HStack(spacing: 8) {
            PhotosPicker(
                selection: $photoItems,
                maxSelectionCount: max(
                    0,
                    PostComposerModel.maximumImageCount - model.activeAttachmentCount
                ),
                matching: .images
            ) {
                Label("Photos", systemImage: "photo.on.rectangle")
                    .frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityIdentifier("composer-photos")
            Button {
                showsFileImporter = true
            } label: {
                Label("Files", systemImage: "folder")
                    .frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityIdentifier("composer-files")
            Button {
                showsGIFPicker = true
            } label: {
                Text("GIF")
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 4)
                    .overlay {
                        RoundedRectangle(cornerRadius: 5)
                            .strokeBorder(lineWidth: 1.5)
                    }
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(.rect)
            }
            .accessibilityLabel("Choose GIF")
            .accessibilityIdentifier("composer-gif")
            Button {
                model.addDraft()
                focusedDraftID = model.activeDraftID
            } label: {
                Label("Add Post", systemImage: "plus.circle")
                    .frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityIdentifier("composer-add-post")
            Spacer(minLength: 0)
            ComposerCharacterCountView(
                count: model.text(for: model.activeDraftID).count,
                limit: PostComposerModel.maximumCharacterCount
            )
            .accessibilityIdentifier("composer-character-count")
        }
        .labelStyle(.iconOnly)
        .font(.title3)
        .foregroundStyle(.tint)
        .sensoryFeedback(.selection, trigger: showsFileImporter)
        .sensoryFeedback(.selection, trigger: showsGIFPicker)
        .sensoryFeedback(.selection, trigger: model.drafts.count)
    }

    @ViewBuilder
    private func draftComposer(_ draft: PostComposerModel.Draft) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            MentionComposerField(
                prompt: draft.id == model.drafts.first?.id ? firstPrompt : "Add another post",
                text: Binding(
                    get: { model.text(for: draft.id) },
                    set: { model.updateText($0, for: draft.id) }
                ),
                resolvedMentions: model.mentions(for: draft.id),
                focus: $focusedDraftID,
                draftID: draft.id,
                accentColor: selectedThemeColor
            ) { handle, did in
                model.setMention(handle: handle, did: did, for: draft.id)
            }
            .simultaneousGesture(
                TapGesture().onEnded { model.activate(draft.id) }
            )
            .task(id: draft.text) {
                await model.resolveLinkPreview(for: draft.id, using: services.resolveLinkPreview)
            }

            if let linkPreview = model.linkPreview(for: draft.id) {
                ExternalEmbedView(embed: linkPreview)
            }

            if !draft.attachments.isEmpty {
                PostComposerAttachmentsView(
                    attachments: draft.attachments,
                    onRemove: model.remove,
                    onEditAltText: { attachmentForAltText = $0 },
                    onMove: model.moveAttachment,
                    isGeneratingAltText: isGeneratingAltTextForAll,
                    allowsAltTextGeneration: allowsComposerAltTextGeneration,
                    onAddAltTextToAll: { generateAltTextForAll(in: draft) }
                )

                if requiresAltText, draft.attachments.contains(where: { attachment in
                    attachment.altText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }) {
                    Label("Add alt text to every image before posting.", systemImage: "exclamationmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if draft.id != model.drafts.last?.id {
                Divider()
            }
        }
    }

    private var requiresAltText: Bool {
        settings.first?.requiresAltText ?? false
    }

    private var allowsComposerAltTextGeneration: Bool {
        settings.first?.allowsComposerAltTextGeneration ?? true
    }

    private var selectedThemeColor: Color {
        Color.accentColor
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )
    }

    private var composerErrorTitle: LocalizedStringKey {
        model.errorMessage?.contains("publish") == true
            ? "Couldn’t Publish Post"
            : "Couldn’t Add Attachment"
    }

    private func importPhotos(_ items: [PhotosPickerItem]) async {
        let selectedItems = Array(items.prefix(max(0, PostComposerModel.maximumImageCount - model.activeAttachmentCount)))
        beginImagePreparation(count: selectedItems.count)
        defer { finishImagePreparation() }
        for item in selectedItems {
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            let mimeType = item.supportedContentTypes.first?.preferredMIMEType ?? "image/jpeg"
            guard let image = await prepareImage(data, mimeType: mimeType) else {
                model.errorMessage = "The Social Wire couldn’t prepare that image for upload."
                continue
            }
            model.addImage(data: image.data, mimeType: image.mimeType)
            imagePreparationCompleted += 1
        }
        photoItems = []
    }

    private func importFiles(_ result: Result<[URL], any Error>) async {
        guard case .success(let urls) = result else {
            model.errorMessage = "The Social Wire couldn’t read the selected file."
            return
        }
        let selectedURLs = Array(urls.prefix(max(0, PostComposerModel.maximumImageCount - model.activeAttachmentCount)))
        beginImagePreparation(count: selectedURLs.count)
        defer { finishImagePreparation() }
        for url in selectedURLs {
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { continue }
            let mimeType = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "image/jpeg"
            guard let image = await prepareImage(data, mimeType: mimeType) else {
                model.errorMessage = "The Social Wire couldn’t prepare that image for upload."
                continue
            }
            model.addImage(data: image.data, mimeType: image.mimeType)
            imagePreparationCompleted += 1
        }
    }

    private func importGIF(_ gif: KlipyGIF) async {
        guard let (data, _) = try? await URLSession.shared.data(from: gif.previewURL) else {
            model.errorMessage = "The Social Wire couldn’t download that GIF."
            return
        }
        model.addGIF(gif, previewData: data)
    }

    private func generateAltTextForAll(in draft: PostComposerModel.Draft) {
        guard !isGeneratingAltTextForAll else { return }
        isGeneratingAltTextForAll = true
        Task {
            defer { isGeneratingAltTextForAll = false }
            for attachment in draft.attachments where attachment.altText.isEmpty {
                do {
                    let altText = try await FoundationModelService().altText(
                        for: attachment.data,
                        mimeType: attachment.mimeType
                    )
                    model.updateAltText(altText, for: attachment.id)
                } catch is CancellationError {
                    return
                } catch {
                    model.errorMessage = error.localizedDescription
                    return
                }
            }
        }
    }

    private func prepareImage(_ data: Data, mimeType: String) async -> (data: Data, mimeType: String)? {
        await Task.detached(priority: .userInitiated) {
            ComposerImageProcessor.prepare(data, mimeType: mimeType)
        }.value
    }

    private func beginImagePreparation(count: Int) {
        imagePreparationCompleted = 0
        imagePreparationTotal = count
    }

    private func finishImagePreparation() {
        imagePreparationCompleted = 0
        imagePreparationTotal = 0
    }
}

#endif
