import SwiftUI

struct SportsEntityOverview: View {
    let entity: SportsEntity
    let events: SportsEventsResponse?
    let eventsError: String?
    let eventsEnabled: Bool
    let hideScores: Bool
    let entities: [SportsEntity]
    var now = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(entity.kind.capitalized, systemImage: entity.systemImage)
                .font(.caption).foregroundStyle(.secondary)
            if let sport = entities.first(where: { $0.id == entity.sportID }) {
                Text(sport.displayName).font(.subheadline).foregroundStyle(.secondary)
            }
            if !hideScores, let event = events?.featuredEvent(now: now) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(event.status == "in-progress" ? "Current Event" : "Latest Result").font(.headline)
                    Text(event.title).font(.subheadline.bold())
                    eventDate(event)
                    if let home = event.homeScore, let away = event.awayScore {
                        Text("\(event.homeName ?? "Home") \(home) – \(away) \(event.awayName ?? "Away")")
                            .font(.subheadline.monospacedDigit())
                    }
                    if let activity = event.activityLabel(now: now, hideScores: false) {
                        Text(activity).font(.caption.bold()).foregroundStyle(.red)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12).background(.quaternary, in: .rect(cornerRadius: 12))
            }
            let upcoming = events?.upcomingEvents(now: now) ?? []
            if !upcoming.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Upcoming Schedule").font(.headline)
                    ForEach(upcoming) { event in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(event.title).font(.subheadline.bold())
                            eventDate(event)
                            if !hideScores, event.status == "postponed" {
                                Text("Postponed").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } else {
                Text(eventsEnabled ? "No Upcoming Fixtures Available" : "Schedule Data Is Not Available for This Feed")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if events != nil {
                Text("Schedule Data by TheSportsDB").font(.caption).foregroundStyle(.secondary)
                if events?.degraded == true { Text("Cached Event Data").font(.caption).foregroundStyle(.secondary) }
                if let raw = events?.updatedAt, let date = ISO8601DateFormatter().date(from: raw) {
                    Text("Data Updated \(date.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            SportsEventsStrip(events: events, error: eventsError, hideScores: hideScores, entities: entities, showScheduleCards: false)
        }
        .padding(14)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 16))
    }

    @ViewBuilder
    private func eventDate(_ event: SportsEvent) -> some View {
        Text(event.scheduleDateLabel).font(.caption).foregroundStyle(.secondary)
    }
}
