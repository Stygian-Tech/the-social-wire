import SwiftUI

/// A primary bulk-read action with calendar-day alternatives on secondary click or long press.
struct FeedMarkReadButton: View {
    @Environment(\.scenePhase) private var scenePhase
    let contextID: String
    var refreshRevision = 0
    let scopeTitle: String
    let loadOptions: (@escaping @MainActor ([FeedReadAgeOption]) -> Void) async throws -> [FeedReadAgeOption]
    let markAllRead: () async -> Void
    let markOlderRead: (FeedReadAgeOption) async throws -> Void
    let markAllUnread: () async -> Void

    @State private var options: [FeedReadAgeOption] = []
    @State private var isLoading = true
    @State private var loadFailed = false
    @State private var isMarking = false
    @State private var showsConfirmation = false
    @State private var selectedAge: FeedReadAgeOption?
    @State private var actionError: String?
    @State private var successFeedback = 0
    @State private var refreshID = UUID()
    @State private var loadedContextID: String?
    @State private var refreshTask: Task<Void, Never>?

    var body: some View {
        Button("Mark All As Read", systemImage: "checkmark.circle") {
            selectedAge = nil
            showsConfirmation = true
        }
        .accessibilityIdentifier("feed-mark-all-read")
        .disabled(isMarking)
        .contextMenu {
            Section("Older Than") {
                ForEach(options) { option in
                    Button {
                        selectedAge = option
                        showsConfirmation = true
                    } label: {
                        Text("\(option.title) (\(option.count)\(isLoading ? "+" : ""))")
                    }
                    .disabled(isLoading || isMarking || loadedContextID != contextID)
                    .accessibilityLabel("Older Than \(option.title), \(isLoading ? "At Least " : "")\(option.count) Unread Stories")
                    .accessibilityIdentifier("mark-read-age-\(option.days)")
                }
                if isLoading {
                    Text(options.isEmpty ? "Loading Days…" : "Counting Stories…")
                } else if loadFailed {
                    Button("Retry Loading Days", systemImage: "arrow.clockwise") {
                        Task { await refreshOptions() }
                    }
                } else if options.isEmpty {
                    Text("No Older Unread Stories")
                }
            }
            Divider()
            Button("Mark All As Unread") {
                Task {
                    isMarking = true
                    await markAllUnread()
                    isMarking = false
                    await refreshOptions()
                }
            }
        }
        .alert(selectedAge == nil ? "Mark All As Read?" : "Mark Older Stories As Read?", isPresented: $showsConfirmation) {
            Button("Mark As Read") {
                let age = selectedAge
                Task { await confirm(age: age) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let age = selectedAge, let cutoff = age.cutoffDate {
                Text("Mark unread stories in \(scopeTitle) published before \(cutoff.formatted(date: .abbreviated, time: .omitted)) as read? Newer stories stay unread.")
            } else {
                Text("Mark every unread story in \(scopeTitle) as read?")
            }
        }
        .alert("Couldn't Mark Stories As Read", isPresented: Binding(
            get: { actionError != nil },
            set: { if !$0 { actionError = nil } }
        )) {
            Button("OK", role: .cancel) { actionError = nil }
        } message: {
            Text(actionError ?? "Please try again.")
        }
        .sensoryFeedback(.success, trigger: successFeedback)
        .task(id: "\(contextID):\(refreshRevision)") {
            let contextChanged = loadedContextID != contextID
            if contextChanged {
                loadedContextID = contextID
                showsConfirmation = false
                selectedAge = nil
                options = []
            }
            await refreshOptions(debounce: !contextChanged)
        }
        .onDisappear {
            refreshTask?.cancel()
            refreshID = UUID()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await refreshOptions() }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
            Task { await refreshOptions() }
        }
    }

    private func refreshOptions(debounce: Bool = false) async {
        refreshTask?.cancel()
        let requestID = UUID()
        refreshID = requestID
        options = []
        isLoading = true
        loadFailed = false
        let task = Task { @MainActor in
            do {
                // Coalesce read-state updates while immediately invalidating the prior stream.
                if debounce { try await Task.sleep(for: .milliseconds(350)) }
                let loaded = try await loadOptions { partial in
                    guard !Task.isCancelled, refreshID == requestID else { return }
                    options = validOptions(partial)
                }
                guard !Task.isCancelled, refreshID == requestID else { return }
                options = validOptions(loaded)
            } catch {
                guard !Task.isCancelled, refreshID == requestID else { return }
                options = []
                loadFailed = true
            }
            isLoading = false
        }
        refreshTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func validOptions(_ options: [FeedReadAgeOption]) -> [FeedReadAgeOption] {
        options.filter { (1...7).contains($0.days) && $0.count > 0 && $0.cutoffDate != nil }
            .sorted { $0.days < $1.days }
    }

    private func confirm(age: FeedReadAgeOption?) async {
        isMarking = true
        defer { isMarking = false }
        do {
            if let age {
                try await markOlderRead(age)
            } else {
                await markAllRead()
            }
            successFeedback += 1
            await refreshOptions()
        } catch {
            actionError = error.localizedDescription
            await refreshOptions()
        }
    }
}
