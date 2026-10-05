import SwiftUI

struct SportsEventsStrip: View {
    let events: SportsEventsResponse?
    let error: String?
    let hideScores: Bool
    var entities: [SportsEntity] = []
    var showScheduleCards = true
    @Environment(\.openURL) private var openURL
    @State private var showingStandings = false
    @State private var selectedTablesTab = "standings"

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showScheduleCards, let events, !events.events.isEmpty {
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 12) {
                        ForEach(events.events) { event in
                            VStack(alignment: .leading, spacing: 6) {
                                if let context = SportsEntity.eventContext(competitionID: event.competitionID, entities: entities) {
                                    Text(context).font(.caption).foregroundStyle(.secondary)
                                }
                                Text(event.title).font(.subheadline.bold()).lineLimit(2)
                                Text(event.scheduleDateLabel).font(.caption)
                                if let activity = event.activityLabel(now: Date(), hideScores: hideScores) {
                                    Label(activity, systemImage: event.status == "in-progress" ? "dot.radiowaves.left.and.right" : "checkmark.circle")
                                        .font(.caption.bold()).foregroundStyle(.red)
                                }
                                if !hideScores {
                                    if let status = event.scheduleStatusLabel {
                                        Text(status).font(.caption).foregroundStyle(.secondary)
                                    }
                                    if let home = event.homeScore, let away = event.awayScore {
                                        Text("\(event.homeName ?? "Home") \(home) – \(away) \(event.awayName ?? "Away")")
                                            .font(.subheadline.monospacedDigit())
                                    }
                                }
                            }
                            .frame(width: 220, alignment: .leading)
                            .padding(12)
                            .background(.quaternary, in: .rect(cornerRadius: 12))
                            .overlay {
                                if event.activityLabel(now: Date(), hideScores: hideScores) != nil {
                                    RoundedRectangle(cornerRadius: 12).stroke(.red, lineWidth: 1.5)
                                }
                            }
                        }
                    }
                }
                if let earliest = events.events.compactMap({ ISO8601DateFormatter().date(from: $0.startsAt) }).min(),
                   let latest = events.events.compactMap({ ISO8601DateFormatter().date(from: $0.startsAt) }).max() {
                    Text("Schedule Coverage: \(earliest.formatted(date: .abbreviated, time: .omitted)) – \(latest.formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                if events.eventsLimited == true {
                    Text("Showing Up to 500 Prioritized Events. Choose a Specific Feed to Narrow the Schedule.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Text(events.degraded ? "Cached Event Data" : "Event Data by TheSportsDB")
                    .font(.caption).foregroundStyle(.secondary)
                if let raw = events.updatedAt, let date = ISO8601DateFormatter().date(from: raw) {
                    Text("Updated \(date.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            } else if showScheduleCards, let events, events.events.isEmpty {
                Text("No Matching Schedules Yet").font(.caption).foregroundStyle(.secondary)
            } else if let error {
                Text(error).font(.caption).foregroundStyle(.secondary)
            }
            if !hideScores, events?.standings?.isEmpty == false || events?.bracketSources?.isEmpty == false {
                Button("Standings", systemImage: "list.number") { showingStandings = true }
                    .buttonStyle(.bordered)
            }
        }
        .sheet(isPresented: $showingStandings) {
            NavigationStack {
                VStack(spacing: 0) {
                    Picker("Sports Tables", selection: $selectedTablesTab) {
                        Text("Standings").tag("standings")
                        Text("Brackets").tag("brackets")
                        Text("Sources").tag("sources")
                    }.pickerStyle(.segmented).padding()
                    List {
                        if !hideScores {
                            if selectedTablesTab == "sources" {
                                sourceReferences
                            } else if selectedTablesTab == "brackets" {
                                if events?.bracketSources?.isEmpty != false {
                                    Text("No Reviewed Bracket Sources for This Feed Yet")
                                        .foregroundStyle(.secondary)
                                }
                                ForEach(events?.bracketSources ?? []) { source in
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text(source.title).font(.headline)
                                        Text(source.season).font(.subheadline).foregroundStyle(.secondary)
                                        bracketProvenance(source)
                                        if let url = source.externalURL {
                                            Button("Open Official Bracket", systemImage: "arrow.up.right.square") { openURL(url) }
                                        }
                                    }.padding(.vertical, 6)
                                }
                            } else {
                                if events?.standings?.isEmpty != false {
                                    Text("No Standings for This Feed Yet").foregroundStyle(.secondary)
                                }
                                ForEach(events?.standings ?? []) { table in
                                    SportsStandingsView(table: table, competitionName: SportsEntity.eventContext(competitionID: table.competitionID, entities: entities))
                                }
                            }
                        }
                    }
                }
                .navigationTitle(selectedTablesTab == "sources" ? "Sources" : selectedTablesTab == "brackets" ? "Brackets" : "Standings")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { showingStandings = false }
                    }
                }
            }
        }
        .onChange(of: hideScores) { _, hidden in
            if hidden { showingStandings = false }
        }
    }

    @ViewBuilder
    private func bracketProvenance(_ source: SportsBracketSource) -> some View {
        if let host = source.externalURL?.host {
            Text("Official External Reference: \(host)").font(.caption).foregroundStyle(.secondary)
        }
        if let date = source.reviewedDateLabel() {
            Text("Link Reviewed \(date) (UTC)")
                .font(.caption2).foregroundStyle(.secondary)
        }
        Text("Open the Organizer’s Site for the Bracket. Live Bracket Data Is Not Shown Here.")
            .font(.caption).foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var sourceReferences: some View {
        ForEach(events?.standings ?? []) { table in
            Section(SportsEntity.eventContext(competitionID: table.competitionID, entities: entities) ?? "Standings") {
                Text("Season \(table.season)").font(.subheadline)
                if let url = table.providerURL {
                    Link("Data Provider: \(table.providerName)", destination: url)
                    Text(url.host ?? "").font(.caption).foregroundStyle(.secondary)
                }
                if let raw = table.updatedAt, let date = ISO8601DateFormatter().date(from: raw) {
                    Text("Data Updated \(date.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if table.degraded { Text("Cached Standings").font(.caption).foregroundStyle(.secondary) }
                let rules = table.rows.compactMap(\.zone).reduce(into: [SportsStandingZone]()) { result, zone in
                    if !result.contains(where: { $0.sourceURL == zone.sourceURL }) { result.append(zone) }
                }
                ForEach(Array(rules.enumerated()), id: \.offset) { _, zone in
                    if let url = URL(string: zone.sourceURL), url.scheme == "https" {
                        Link("Table Zone Rules: \(zone.label)", destination: url)
                    }
                }
            }
        }
        ForEach(events?.bracketSources ?? []) { source in
            Section(source.title) {
                Text("Season \(source.season)").font(.subheadline)
                bracketProvenance(source)
                if let url = source.externalURL {
                    Button("Open Official Bracket", systemImage: "arrow.up.right.square") { openURL(url) }
                }
            }
        }
        if events?.standings?.isEmpty != false, events?.bracketSources?.isEmpty != false {
            Text("No Reviewed Sources for This Feed Yet").foregroundStyle(.secondary)
        }
    }
}
