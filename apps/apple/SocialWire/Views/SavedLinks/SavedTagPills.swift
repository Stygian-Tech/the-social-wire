import SwiftUI

struct SavedTagPills: View {
    let tags: [String]

    var body: some View {
        if !tags.isEmpty {
            HStack(spacing: 6) {
                ForEach(Array(tags.prefix(3)), id: \.self) { tag in
                    Text(tag)
                        .font(.caption2)
                        .lineLimit(1)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(.quaternary, in: Capsule())
                }
                if tags.count > 3 {
                    Text("+\(tags.count - 3)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Tags: \(tags.joined(separator: ", "))")
        }
    }
}

struct SavedTagFilterBar: View {
    let tags: [SavedTagCount]
    let selection: String?
    let onSelect: (String?) -> Void

    var body: some View {
        if !tags.isEmpty || selection != nil {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    filterButton(title: "All Tags", count: nil, tag: nil)
                    ForEach(tags) { item in
                        filterButton(title: item.tag, count: item.count, tag: item.tag)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
            .background(.bar)
        }
    }

    private func filterButton(title: String, count: Int?, tag: String?) -> some View {
        let selected = selection == tag
        return Button {
            onSelect(tag)
        } label: {
            HStack(spacing: 5) {
                Text(title)
                if let count { Text("\(count)").foregroundStyle(selected ? .white.opacity(0.8) : .secondary) }
            }
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .foregroundStyle(selected ? Color.white : Color.primary)
            .background(selected ? Color.accentColor : Color.secondary.opacity(0.14), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
