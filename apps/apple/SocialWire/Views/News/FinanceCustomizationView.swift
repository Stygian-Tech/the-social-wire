import SwiftUI

struct FinanceCustomizationView: View {
    @Environment(SocialWireAppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var pendingKind = "instrument"
    @State private var pendingReference: String?
    @State private var showingDisclosure = false
    @State private var acceptedDisclosure = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Show Finance", isOn: Binding(get: { appModel.feedPreferences.showFinance }, set: { value in
                        Task { await appModel.setFinanceVisible(value) }
                    }))
                    Toggle("Hide Performance Data", isOn: Binding(get: { appModel.feedPreferences.hideFinancePerformance }, set: { value in
                        Task { await appModel.setFinancePerformanceHidden(value) }
                    }))
                }
                Section("Instruments") {
                    TextField("Search Instruments", text: $query)
                    ForEach(appModel.financeSearchResults) { instrument in
                        selectionButton(kind: "instrument", reference: instrument.id,
                                        title: "\(instrument.name) · \(instrument.symbol) · \(instrument.exchangeLabel ?? instrument.kind)")
                    }
                }
                Section("Sectors") {
                    ForEach(appModel.financeSectors) { sector in
                        selectionButton(kind: "sector", reference: sector.id, title: sector.name)
                    }
                }
                Section("Public Selections") {
                    Text("Selections express interests, not ownership. They are public PDS records that others may copy. Removing a selection deletes your record and app projection, but cannot delete downstream copies.")
                        .font(.footnote)
                    ForEach(appModel.financeSelections, id: \.key) { selection in
                        selectionButton(kind: selection.kind, reference: selection.reference, title: selectionTitle(selection))
                    }
                }
                if let error = appModel.financeError { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle("Customize Finance")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { await appModel.loadFinanceCustomization() }
            .task(id: query) {
                do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
                await appModel.searchFinance(query)
            }
            .alert("Public Finance Interests", isPresented: $showingDisclosure) {
                Button("Cancel", role: .cancel) { pendingReference = nil }
                Button("Save Public Selection") {
                    acceptedDisclosure = true
                    if let pendingReference { Task { await appModel.toggleFinanceSelection(kind: pendingKind, reference: pendingReference) } }
                }
            } message: {
                Text("This interest will be stored publicly on your PDS. Others may copy it. It does not indicate ownership, and removal cannot erase downstream copies.")
            }
        }
    }

    private func selectionTitle(_ selection: FinanceSelectionRecord) -> String {
        if selection.kind == "sector" {
            return appModel.financeSectors.first(where: { $0.id == selection.reference })?.name ?? "Unavailable Sector"
        }
        guard let instrument = appModel.financeInstrumentMetadata[selection.reference] else { return "Unavailable Instrument" }
        return "\(instrument.name) · \(instrument.symbol) · \(instrument.exchangeLabel ?? instrument.kind)"
    }

    private func selectionButton(kind: String, reference: String, title: String) -> some View {
        let selected = appModel.financeSelections.contains { $0.kind == kind && $0.reference == reference }
        return Button {
            if !selected, !acceptedDisclosure {
                pendingKind = kind
                pendingReference = reference
                showingDisclosure = true
            } else {
                Task { await appModel.toggleFinanceSelection(kind: kind, reference: reference) }
            }
        } label: {
            HStack { Text(title); Spacer(); if selected { Image(systemName: "checkmark") } }
        }
        .disabled(appModel.isSavingFinanceSelection || (!selected && kind == "instrument" && appModel.financeInstrumentMetadata[reference]?.isActive == false))
        .accessibilityValue(selected ? "Selected" : "Not Selected")
    }
}
