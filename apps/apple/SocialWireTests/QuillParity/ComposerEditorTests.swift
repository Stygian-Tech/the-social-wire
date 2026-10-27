#if os(iOS)
import SwiftUI
import Testing
import UIKit
@testable import QuillSocialUI

@Suite("Composer Editor", .serialized)
@MainActor
struct ComposerEditorTests {
    private struct FocusedEditor: View {
        let draftID = UUID()
        @State private var text = String(repeating: "A long draft line\n", count: 40)
        @FocusState private var focus: UUID?

        var body: some View {
            MentionComposerField(
                prompt: "Write a reply", text: $text, resolvedMentions: [:],
                focus: $focus, draftID: draftID, selectMention: { _, _ in }
            )
            .padding()
            .task {
                await Task.yield()
                focus = draftID
            }
        }
    }

    @Test("Focus reaches the native editor and long drafts remain scrollable")
    func editorFocusAndLongDraft() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let host = UIHostingController(rootView: FocusedEditor())
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 375, height: 650)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            host.view.endEditing(true)
            window.isHidden = true
            previousKeyWindow?.makeKey()
        }
        host.view.layoutIfNeeded()
        for _ in 0..<20 {
            if nativeEditor(in: host.view)?.isFirstResponder == true { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        let editor = try #require(nativeEditor(in: host.view))
        #expect(editor.isFirstResponder)
        #expect(editor.isScrollEnabled)
        #expect(editor.contentSize.height > editor.bounds.height)
        let lastCharacter = max(0, (editor.text as NSString).length - 1)
        editor.scrollRangeToVisible(NSRange(location: lastCharacter, length: 1))
        // TextKit lays out offscreen glyphs and applies the scroll on a later turn.
        for _ in 0..<20 {
            if editor.contentOffset.y > 0 { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(editor.contentOffset.y > 0)
    }

    @Test("Long attribution handles retain a single compact row")
    func longAttributionHandle() {
        func size(_ handle: String) -> CGSize {
            let host = UIHostingController(rootView:
                ProfileAttributionChip(title: "Replying To", avatarURL: nil, handle: handle)
                    .frame(width: 300, alignment: .leading)
            )
            return host.sizeThatFits(in: CGSize(width: 300, height: 1_000))
        }
        let short = size("test.example")
        let long = size(String(repeating: "a-long-handle", count: 12) + ".bsky.social")
        #expect(abs(short.height - long.height) < 1)
        #expect(long.width <= 301)
    }

    private func nativeEditor(in view: UIView) -> UITextView? {
        if let editor = view as? UITextView { return editor }
        return view.subviews.lazy.compactMap { nativeEditor(in: $0) }.first
    }
}

#endif
