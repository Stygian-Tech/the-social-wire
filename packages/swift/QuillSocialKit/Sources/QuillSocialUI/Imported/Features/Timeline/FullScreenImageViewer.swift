#if os(iOS)
import Feeds
import SwiftData
import SwiftUI

struct FullScreenImageViewer: View {
    let images: [TimelineImage]

    @Environment(\.dismiss) private var dismiss
    @State private var selectedImageID: TimelineImage.ID
    @State private var altTextModel = ViewerAltTextModel()
    @State private var dismissFeedbackTrigger = 0
    @State private var zoomedImageIDs: Set<TimelineImage.ID> = []
    @GestureState private var dismissalOffset = 0.0
    @Query private var settings: [AppSettings]

    init(
        images: [TimelineImage],
        selectedImageID: TimelineImage.ID
    ) {
        self.images = images
        _selectedImageID = State(initialValue: selectedImageID)
    }

    var body: some View {
        NavigationStack {
            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(images) { image in
                        ZoomableRemoteImage(image: image, isActive: image.id == selectedImageID) { isZoomed in
                            if isZoomed {
                                zoomedImageIDs.insert(image.id)
                            } else {
                                zoomedImageIDs.remove(image.id)
                            }
                        }
                        .containerRelativeFrame(.horizontal)
                        .id(image.id)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollIndicators(.hidden)
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: Binding<TimelineImage.ID?>(
                get: { selectedImageID },
                set: { if let id = $0 { selectedImageID = id } }
            ))
            .scrollDisabled(zoomedImageIDs.contains(selectedImageID))
            .background(.black)
            .overlay(alignment: .bottom) {
                if images.count > 1 {
                    HStack(spacing: 0) {
                        ForEach(images) { image in
                            Button {
                                selectedImageID = image.id
                            } label: {
                                Circle()
                                    .fill(.white.opacity(image.id == selectedImageID ? 1 : 0.4))
                                    .frame(width: 7, height: 7)
                                    .padding(8)
                                    .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.bottom, 20)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Image \((images.firstIndex { $0.id == selectedImageID } ?? 0) + 1) of \(images.count)")
                    .accessibilityAdjustableAction { direction in
                        guard let index = images.firstIndex(where: { $0.id == selectedImageID }) else { return }
                        switch direction {
                        case .increment:
                            selectedImageID = images[min(index + 1, images.count - 1)].id
                        case .decrement:
                            selectedImageID = images[max(index - 1, 0)].id
                        @unknown default:
                            break
                        }
                    }
                }
            }
            .overlay(alignment: .bottom) {
                altTextOverlay
                    .padding(.horizontal)
                    .padding(.bottom, images.count > 1 ? 52 : 12)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done", systemImage: "xmark") { dismiss() }
                        .labelStyle(.iconOnly)
                }
            }
            .toolbarColorScheme(.dark, for: .navigationBar)
            .onChange(of: selectedImageID) {
                altTextModel.select(selectedImageID)
            }
            .task(id: selectedImageID) { await generateAltTextIfNeeded() }
        }
        .offset(y: dismissalOffset)
        .scaleEffect(1 - min(abs(dismissalOffset) / 1_500, 0.08))
        .simultaneousGesture(dismissGesture, including: zoomedImageIDs.contains(selectedImageID) ? .subviews : .all)
        .sensoryFeedback(.impact(weight: .light), trigger: dismissFeedbackTrigger)
    }

    @ViewBuilder
    private var altTextOverlay: some View {
        if let image = selectedImage {
            if !image.altText.isEmpty {
                descriptionOverlay(image.altText, isGenerated: false)
            } else if let generatedAltText = altTextModel.generatedText {
                descriptionOverlay(generatedAltText, isGenerated: true)
            } else if let altTextError = altTextModel.errorMessage {
                descriptionOverlay(altTextError, isGenerated: false)
            } else if altTextModel.isGenerating {
                ProgressView("Generating Alt Text")
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.black.opacity(0.35), in: .capsule)
            }
        }
    }

    private func descriptionOverlay(_ text: String, isGenerated: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if isGenerated {
                Image(systemName: "apple.intelligence")
                    .accessibilityLabel("Generated Alt Text")
            }
            Text(text)
        }
            .font(.callout)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(.black.opacity(0.35), in: .rect(cornerRadius: 12))
    }

    private var selectedImage: TimelineImage? {
        images.first { $0.id == selectedImageID }
    }

    private var allowsViewerGeneration: Bool {
        settings.first?.allowsViewerAltTextGeneration ?? true
    }

    private var dismissGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .updating($dismissalOffset) { value, offset, _ in
                guard !zoomedImageIDs.contains(selectedImageID) else { return }
                guard PhotoViewerDismissGestureEvaluator.isVerticalIntent(value.translation) else { return }
                offset = value.translation.height
            }
            .onEnded { value in
                guard !zoomedImageIDs.contains(selectedImageID) else { return }
                guard PhotoViewerDismissGestureEvaluator.shouldDismiss(
                    translation: value.translation,
                    predictedEndTranslation: value.predictedEndTranslation
                ) else { return }
                dismissFeedbackTrigger += 1
                dismiss()
            }
    }

    private func generateAltTextIfNeeded() async {
        guard allowsViewerGeneration,
              let image = selectedImage,
              image.altText.isEmpty else { return }
        await altTextModel.generateIfNeeded(for: image.id)
    }
}

#endif
