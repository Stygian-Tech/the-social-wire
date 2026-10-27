import SwiftUI

struct NewsSectionCustomizationView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var preferences: NewsSectionPreferences
    @State private var isReordering = false

    private var unpinnedSections: [NewsRootSection] {
        NewsRootSection.allCases.filter { !preferences.pinnedSections.contains($0) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(preferences.pinnedSections) { section in
                        Button {
                            preferences.setPinned(false, section: section)
                        } label: {
                            Label(section.title, systemImage: section.systemImage)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .accessibilityHint("Remove From Bottom Bar")
                        .accessibilityIdentifier("section-unpin-\(section.rawValue)")
                    }
                    .onMove { offsets, destination in
                        var sections = preferences.pinnedSections
                        sections.move(fromOffsets: offsets, toOffset: destination)
                        preferences = NewsSectionPreferences(pinnedSections: sections)
                    }
                    .onDelete { offsets in
                        var sections = preferences.pinnedSections
                        sections.remove(atOffsets: offsets)
                        preferences = NewsSectionPreferences(pinnedSections: sections)
                    }
                } header: {
                    Text("Favorites (\(preferences.pinnedSections.count)/\(NewsSectionPreferences.maximumPinnedSections))")
                } footer: {
                    Text("Choose up to four favorites and drag to reorder them. Browse and the sidebar always include every section.")
                }

                Section("Available Sections") {
                    ForEach(unpinnedSections) { section in
                        Button {
                            preferences.setPinned(true, section: section)
                        } label: {
                            HStack {
                                Label(section.title, systemImage: section.systemImage)
                                Spacer()
                                Image(systemName: "plus.circle").accessibilityHidden(true)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .disabled(preferences.pinnedSections.count >= NewsSectionPreferences.maximumPinnedSections)
                        .accessibilityHint("Add to Bottom Bar")
                        .accessibilityIdentifier("section-pin-\(section.rawValue)")
                    }
                }
            }
            #if os(iOS)
            .environment(\.editMode, .constant(isReordering ? .active : .inactive))
            #endif
            .navigationTitle("Customize Bottom Bar")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(isReordering ? "Finish Reordering" : "Reorder") {
                        isReordering.toggle()
                    }
                }
            }
        }
    }
}
