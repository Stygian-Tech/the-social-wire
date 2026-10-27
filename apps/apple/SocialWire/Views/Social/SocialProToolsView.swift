import SwiftUI

struct SocialProToolsView: View {
    private let tools = [
        SocialProTool(name: "Articles", systemImage: "doc.text", description: "Draft and publish long-form work."),
        SocialProTool(name: "Live Post", systemImage: "dot.radiowaves.left.and.right", description: "Publish live updates from one workspace."),
        SocialProTool(name: "Livestream", systemImage: "video", description: "Manage your live video presence."),
        SocialProTool(name: "Brand Accounts", systemImage: "person.2", description: "Work across linked publishing identities."),
        SocialProTool(name: "Content Calendar", systemImage: "calendar", description: "Review and manage scheduled posts."),
        SocialProTool(name: "Analytics", systemImage: "chart.xyaxis.line", description: "See performance across your accounts.")
    ]

    var body: some View {
        List(tools) { tool in
            Label {
                VStack(alignment: .leading, spacing: 3) {
                    Text(tool.name).font(.headline)
                    Text(tool.description).font(.caption).foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: tool.systemImage)
            }
        }
        .navigationTitle("Pro Tools")
    }
}

private struct SocialProTool: Identifiable {
    var id: String { name }
    let name: String
    let systemImage: String
    let description: String
}
