import SwiftUI

private let readerListBottomContentMargin: CGFloat = 46

extension View {
    /// Transparent list canvas shared by the legacy reader and adaptive news shell.
    func readerListCanvas() -> some View {
        scrollContentBackground(.hidden)
            .contentMargins(.bottom, readerListBottomContentMargin, for: .scrollContent)
    }

    func readerClearListRow() -> some View {
        listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
    }

    /// Compact source-list spacing for the macOS-style navigation sidebar.
    func readerSidebarListRow() -> some View {
        listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 3, leading: 12, bottom: 3, trailing: 12))
    }

    /// Expand button/list row labels to the full row width for reliable taps.
    func readerFullWidthTapLabel() -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
    }
}
