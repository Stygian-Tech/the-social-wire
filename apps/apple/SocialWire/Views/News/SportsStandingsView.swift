import SwiftUI

struct SportsStandingsView: View {
    let table: SportsStandingSnapshot
    var competitionName: String? = nil

    var body: some View {
        DisclosureGroup(table.season.isEmpty ? (competitionName ?? "Standings") : "\(competitionName ?? "Standings") · \(table.season)") {
            if let url = table.providerURL {
                Link("Data Provider: \(table.providerName)", destination: url).font(.caption)
            }
            if table.status == "available", !table.rows.isEmpty {
                ForEach(table.rows) { row in
                    HStack(alignment: .top) {
                        Text(row.rank.map(String.init) ?? "—").monospacedDigit()
                        VStack(alignment: .leading, spacing: 4) {
                            Text(row.name).font(.subheadline.bold())
                            if let zone = row.zone {
                                Label(zone.label, systemImage: zone.systemImage)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(zoneColor(zone.kind))
                            }
                            if let group = row.group { Text(group).font(.caption).foregroundStyle(.secondary) }
                            Text("Played \(row.played.map(String.init) ?? "—") · Won \(row.won.map(String.init) ?? "—") · Drawn \(row.drawn.map(String.init) ?? "—") · Lost \(row.lost.map(String.init) ?? "—")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("\(row.points ?? "—") Points").font(.caption).monospacedDigit()
                    }.padding(.vertical, 6)
                }
            } else {
                Text(table.status == "unavailable" ? "Standings Unavailable" : "No Standings Yet")
                    .font(.caption).foregroundStyle(.secondary)
            }
            let zones = table.rows.compactMap(\.zone).reduce(into: [SportsStandingZone]()) { result, zone in
                if !result.contains(zone) { result.append(zone) }
            }
            if !zones.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Table Zones").font(.caption.bold())
                    ForEach(Array(zones.enumerated()), id: \.offset) { _, zone in
                        if let url = URL(string: zone.sourceURL), ["https", "http"].contains(url.scheme?.lowercased() ?? "") {
                            Link(destination: url) {
                                Label("Rules: \(zone.label)", systemImage: zone.systemImage)
                            }.font(.caption).foregroundStyle(zoneColor(zone.kind))
                        } else {
                            Label(zone.label, systemImage: zone.systemImage)
                                .font(.caption).foregroundStyle(zoneColor(zone.kind))
                        }
                    }
                    Text("Zones Show Current Table Positions, Not Confirmed Outcomes.")
                        .font(.caption2).foregroundStyle(.secondary)
                }.padding(.vertical, 6)
            }
            if table.degraded { Text("Cached Standings").font(.caption).foregroundStyle(.secondary) }
            if let raw = table.updatedAt, let date = ISO8601DateFormatter().date(from: raw) {
                Text("Updated \(date.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func zoneColor(_ kind: String) -> Color {
        switch kind {
        case "champion": .yellow
        case "promotion": .green
        case "playoff": .blue
        case "relegation": .red
        case "qualification": .purple
        default: .secondary
        }
    }
}
