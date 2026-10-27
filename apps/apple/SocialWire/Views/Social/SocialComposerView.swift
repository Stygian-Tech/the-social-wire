import SwiftUI
import PhotosUI

struct SocialComposerView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model: SocialComposerModel
    @State private var showDiscardConfirmation = false

    init(client: SocialWireSocialClient, replyRoot: SocialPostReference? = nil, replyParent: SocialPostReference? = nil, quote: SocialPostReference? = nil) {
        _model = State(initialValue: SocialComposerModel(client: client, replyRoot: replyRoot, replyParent: replyParent, quote: quote))
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach($model.segments) { $segment in
                    SocialComposerSegmentView(segment: $segment, disabled: model.isPublishing || model.isLocked) {
                        model.removeSegment(id: segment.id)
                    }
                }
                .onMove(perform: model.move)
                Button("Add Post", systemImage: "plus") { model.addSegment() }
                    .disabled(model.isPublishing || model.isLocked)
                if model.segments.count > 1 {
                    Text("Threads Publish in Order. Each Post Replies to the Previous Post.").font(.footnote).foregroundStyle(.secondary)
                }
                if model.isLocked { Text("\(model.completed) of \(model.segments.count) Posts Published. Retry Continues This Thread.").font(.footnote) }
                if let error = model.error { Text(error).foregroundStyle(.red).font(.footnote) }
            }
            .navigationTitle(model.segments.count > 1 ? "New Thread" : "New Post")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { model.isLocked ? (showDiscardConfirmation = true) : dismiss() }.disabled(model.isPublishing)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(model.isLocked ? "Retry Remaining Posts" : model.segments.count > 1 ? "Post Thread" : "Post") {
                        Task { if await model.publish() { dismiss() } }
                    }
                    .disabled(!model.isValid || model.isPublishing)
                }
            }
            .confirmationDialog("Discard the Remaining Draft?", isPresented: $showDiscardConfirmation, titleVisibility: .visible) {
                Button("Discard Remaining Draft", role: .destructive) { dismiss() }
                Button("Keep Draft", role: .cancel) { }
            } message: {
                Text("Published Posts Will Stay on Bluesky. A Post With an Unconfirmed Result May Also Have Published.")
            }
        }
        .interactiveDismissDisabled(model.isPublishing || model.isLocked)
    }
}

private struct SocialComposerSegmentView: View {
    @Binding var segment: SocialThreadDraftSegment
    let disabled: Bool
    let remove: () -> Void
    @State private var selectedPhotos: [PhotosPickerItem] = []
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextEditor(text: $segment.text).frame(minHeight: 110).disabled(disabled)
            ForEach($segment.attachments) { $attachment in
                HStack {
                    Image(systemName: "photo").foregroundStyle(.secondary)
                    TextField("Image Description", text: $attachment.altText)
                    Button("Remove Image", systemImage: "xmark.circle", role: .destructive) {
                        segment.attachments.removeAll { $0.id == attachment.id }
                    }
                    .labelStyle(.iconOnly)
                }
            }
            HStack {
                PhotosPicker(selection: $selectedPhotos, maxSelectionCount: 4 - segment.attachments.count, matching: .images) {
                    Label("Add Photos", systemImage: "photo.on.rectangle.angled")
                }
                .disabled(disabled || segment.attachments.count >= 4)
                if segment.published != nil { Label("Published", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
                Spacer()
                Text("\(segment.graphemeCount)/300").foregroundStyle(segment.isValid ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
                Button("Remove", systemImage: "trash", role: .destructive, action: remove).labelStyle(.iconOnly).disabled(disabled)
            }
            .font(.caption)
        }
        .onChange(of: selectedPhotos) { _, items in
            Task {
                for item in items where segment.attachments.count < 4 {
                    guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
                    let mimeType = item.supportedContentTypes.first?.preferredMIMEType ?? "image/jpeg"
                    segment.attachments.append(.init(data: data, mimeType: mimeType))
                }
                selectedPhotos = []
            }
        }
    }
}
