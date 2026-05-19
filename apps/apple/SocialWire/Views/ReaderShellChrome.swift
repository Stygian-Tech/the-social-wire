import SwiftUI

/// Floating All / Unread control (glass capsule) shown once at the bottom of pager / split content.
struct ReaderFloatingFilterBar: View {
    @Environment(SocialWireAppModel.self) private var appModel

    var body: some View {
        @Bindable var model = appModel

        Picker("Filter", selection: Binding(
            get: { model.readerFilter },
            set: { newValue in Task { await model.applyReaderFilter(newValue) } }
        )) {
            ForEach(ReaderFilter.allCases) { filter in
                Text(filter.rawValue).tag(filter)
            }
        }
        .pickerStyle(.segmented)
        .controlSize(.small)
        .fixedSize(horizontal: true, vertical: false)
        .padding(.horizontal, 4)
        .padding(.vertical, 4)
        .background {
            Capsule(style: .continuous)
                .fill(.ultraThinMaterial)
        }
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(.primary.opacity(0.08), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.14), radius: 8, y: 3)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Articles filter")
    }
}

/// Apply reader toolbar + bottom floating filter once on a parent container (not per pane).
struct ReaderShellOverlayModifier: ViewModifier {
    @Environment(SocialWireAppModel.self) private var appModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Binding var showingProfile: Bool
    var compactPane: ReaderPane?
    @State private var showMarkReadConfirm = false

    private var isCompact: Bool {
        horizontalSizeClass == .compact
    }

    private var markReadScope: ReaderMarkReadScope {
        appModel.markReadScope(compactPane: compactPane, isCompact: isCompact)
    }

    /// All / Unread applies to article lists, not the open reader surface.
    private var showsArticlesFilter: Bool {
        if isCompact {
            return compactPane == .articles
        }
        return appModel.selectedPublication != nil && appModel.selectedEntry == nil
    }

    private var markReadDisabled: Bool {
        appModel.isMarkReadDisabled(for: markReadScope)
    }

    private var markReadIsSingleItem: Bool {
        if case .entry = markReadScope { return true }
        return false
    }

    private var markReadToolbarLabel: String {
        markReadIsSingleItem ? "Mark As Read" : "Mark All As Read"
    }

    private var markReadDialogTitle: String {
        markReadIsSingleItem ? "Mark As Read?" : "Mark All As Read?"
    }

    private var markReadConfirmTitle: String {
        markReadIsSingleItem ? "Mark As Read" : "Mark All As Read"
    }

    private var markReadDialogMessage: String {
        switch markReadScope {
        case .allLists:
            return """
                This marks every cached article across Subscribed and Following as read. \
                Entries that have not been loaded yet stay unchanged until you open them.
                """
        case .list(let source):
            switch source {
            case .readLater:
                return "Read Later uses saved links, not feed read state. Open a publication feed to mark articles as read."
            case .subscribed:
                return """
                    This marks every cached article in Subscribed (folders and publications) as read. \
                    Entries that have not been loaded yet stay unchanged until you open them.
                    """
            case .following:
                return """
                    This marks every cached article from publications you follow as read. \
                    Entries that have not been loaded yet stay unchanged until you open them.
                    """
            }
        case .publication:
            return """
                This marks every cached article in this publication as read. \
                Entries that have not been loaded yet stay unchanged until you open them.
                """
        case .entry:
            return "This marks the open article as read."
        case .unavailable:
            return ""
        }
    }

    func body(content: Content) -> some View {
        content
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showingProfile = true
                    } label: {
                        ViewerProfileAvatar(size: 32)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Profile")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await appModel.refreshAll() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .disabled(appModel.isLoading)
                }

                if markReadScope != .unavailable {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showMarkReadConfirm = true
                        } label: {
                            Label(markReadToolbarLabel, systemImage: "checkmark.circle")
                        }
                        .disabled(markReadDisabled)
                        .accessibilityLabel(markReadToolbarLabel)
                    }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if showsArticlesFilter {
                    HStack {
                        Spacer(minLength: 0)
                        ReaderFloatingFilterBar()
                        Spacer(minLength: 0)
                    }
                    .padding(.top, 6)
                    .padding(.bottom, 8)
                }
            }
            .confirmationDialog(
                markReadDialogTitle,
                isPresented: $showMarkReadConfirm,
                titleVisibility: .visible
            ) {
                Button(markReadConfirmTitle) {
                    Task {
                        await appModel.markRead(for: markReadScope)
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(markReadDialogMessage)
            }
    }
}

extension View {
    func readerShellOverlay(showingProfile: Binding<Bool>, compactPane: ReaderPane? = nil) -> some View {
        modifier(ReaderShellOverlayModifier(showingProfile: showingProfile, compactPane: compactPane))
    }
}
