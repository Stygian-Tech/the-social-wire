import SwiftUI

/// Fixed shortcuts. A sidebar-only destination deliberately leaves every shortcut unselected.
struct NewsSectionBar: View {
    let sections: [NewsRootSection]
    @Binding var selection: NewsRootSection

    var body: some View {
        if !sections.isEmpty {
            HStack(alignment: .top, spacing: 0) {
                ForEach(sections) { section in
                    Button {
                        selection = section
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: section.systemImage)
                                .font(.title3)
                            Text(section.title)
                                .font(.caption2)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .padding(.vertical, 6)
                        .background(selection == section ? Color.accentColor.opacity(0.14) : .clear, in: Capsule())
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(selection == section ? Color.accentColor : .secondary)
                    .accessibilityLabel(Text(section.title))
                    .accessibilityAddTraits(selection == section ? .isSelected : [])
                    .accessibilityIdentifier("section-tab-\(section.rawValue)")
                }
            }
            .padding(6)
            .modifier(NewsSectionBarSurface())
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Sections")
        }
    }
}
