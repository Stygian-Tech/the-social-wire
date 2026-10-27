import SwiftUI

struct NewsSidebarSectionHeader: View {
    let section: NewsRootSection
    let onSelect: (NewsRootSection) -> Void

    var body: some View {
        Button {
            onSelect(section)
        } label: {
            Text(section.title)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .textCase(nil)
        .accessibilityIdentifier("sidebar-section-\(section.rawValue)")
    }
}
